import Foundation
import GRDB

public enum ReadingResourceError: Error, Sendable, Equatable { case invalidResource, messageMissing }

public struct MIMEInlineResourceRecord: Codable, Sendable, Equatable {
    public static let maximumCount = 32
    public static let maximumResourceBytes = 5 * 1_024 * 1_024
    public static let maximumMessageBytes = 20 * 1_024 * 1_024
    public static let allowedMIMETypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    public var accountID: String
    public var messageID: String
    public var contentID: String
    public var partID: String
    public var mimeType: String
    public var data: Data

    public init(accountID: String, messageID: String, contentID: String, partID: String, mimeType: String, data: Data) {
        self.accountID = accountID; self.messageID = messageID; self.contentID = contentID
        self.partID = partID; self.mimeType = mimeType; self.data = data
    }

    /// Content IDs are case-sensitive. Only header whitespace and enclosing brackets are removed.
    public static func normalizedContentID(_ value: String) -> String? {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty, value.utf8.count <= 1024,
              !value.contains("<"), !value.contains(">"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        return value
    }
}

extension CacheTransaction {
    /// Validate the entire replacement before writing; callers commit it with the message body.
    public func replaceMIMEResources(_ resources: [MIMEInlineResourceRecord], messageID: String, accountID: String) throws {
        guard resources.count <= MIMEInlineResourceRecord.maximumCount else { throw ReadingResourceError.invalidResource }
        guard try message(id: messageID, accountID: accountID) != nil else { throw ReadingResourceError.messageMissing }
        var normalized: [MIMEInlineResourceRecord] = []
        var seen = Set<String>()
        var bytes = 0
        for var resource in resources {
            guard resource.accountID == accountID, resource.messageID == messageID,
                  let contentID = MIMEInlineResourceRecord.normalizedContentID(resource.contentID),
                  seen.insert(contentID).inserted, !resource.partID.isEmpty,
                  !resource.data.isEmpty, resource.data.count <= MIMEInlineResourceRecord.maximumResourceBytes else {
                throw ReadingResourceError.invalidResource
            }
            resource.contentID = contentID
            resource.mimeType = resource.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard MIMEInlineResourceRecord.allowedMIMETypes.contains(resource.mimeType) else { throw ReadingResourceError.invalidResource }
            bytes += resource.data.count
            guard bytes <= MIMEInlineResourceRecord.maximumMessageBytes else { throw ReadingResourceError.invalidResource }
            normalized.append(resource)
        }
        try db.execute(sql: "DELETE FROM mimeResource WHERE accountID = ? AND messageID = ?", arguments: [accountID, messageID])
        for resource in normalized {
            try db.execute(sql: "INSERT INTO mimeResource (accountID,messageID,contentID,partID,mimeType,data) VALUES (?,?,?,?,?,?)",
                arguments: [accountID, messageID, resource.contentID, resource.partID, resource.mimeType, resource.data])
        }
    }

    public func mimeResources(messageID: String, accountID: String) throws -> [MIMEInlineResourceRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM mimeResource WHERE accountID = ? AND messageID = ? ORDER BY contentID",
            arguments: [accountID, messageID]).map {
                MIMEInlineResourceRecord(accountID: $0["accountID"], messageID: $0["messageID"], contentID: $0["contentID"],
                    partID: $0["partID"], mimeType: $0["mimeType"], data: $0["data"])
            }
    }

    public func markThreadOpened(threadID: String, accountID: String, at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw ReadingResourceError.invalidResource }
        try db.execute(sql: """
            INSERT INTO threadOpened (accountID,threadID,lastOpenedAt)
            SELECT accountID,id,? FROM thread WHERE accountID = ? AND id = ?
            ON CONFLICT(accountID,threadID) DO UPDATE SET lastOpenedAt = MAX(lastOpenedAt,excluded.lastOpenedAt)
            """, arguments: [date, accountID, threadID])
    }
}

extension MailCache {
    public func mimeResources(messageID: String, accountID: String) async throws -> [MIMEInlineResourceRecord] {
        try await read { try $0.mimeResources(messageID: messageID, accountID: accountID) }
    }

    public func markThreadOpened(threadID: String, accountID: String, at date: Date) async throws {
        try await write { try $0.markThreadOpened(threadID: threadID, accountID: accountID, at: date) }
    }
}
