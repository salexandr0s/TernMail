import Foundation
import GRDB

public struct AttachmentCategoryOverride: Codable, Sendable, Equatable {
    public var accountID: String
    public var messageID: String
    public var partID: String
    public var category: AttachmentCategory
    public var revision: Int64

    public init(accountID: String, messageID: String, partID: String, category: AttachmentCategory, revision: Int64 = 0) {
        self.accountID = accountID; self.messageID = messageID; self.partID = partID
        self.category = category; self.revision = revision
    }
}

extension AccountStore {
    public func attachmentCategoryOverrides(accountID: String, messageIDs: [String]? = nil) async throws -> [AttachmentCategoryOverride] {
        try await writer.read { db in
            try MailPreferencesSQL.requireAccount(accountID, db: db)
            if let messageIDs, messageIDs.isEmpty { return [] }
            if let messageIDs {
                let ids = Array(Set(messageIDs)).sorted()
                var records: [AttachmentCategoryOverride] = []
                for start in stride(from: 0, to: ids.count, by: 400) {
                    let chunk = Array(ids[start..<min(start + 400, ids.count)])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    records += try Row.fetchAll(db, sql: """
                        SELECT * FROM attachmentCategoryOverride WHERE accountID = ? AND messageID IN (\(placeholders)) ORDER BY messageID,partID
                        """, arguments: [accountID] + StatementArguments(chunk)).map(AttachmentCategorySQL.record)
                }
                return records
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM attachmentCategoryOverride WHERE accountID = ? ORDER BY messageID,partID",
                arguments: [accountID]).map(AttachmentCategorySQL.record)
        }
    }

    /// Returns the committed revision for the cache projection. A stale index read cannot replace a newer choice.
    @discardableResult
    public func saveAttachmentCategoryOverride(_ value: AttachmentCategoryOverride) async throws -> AttachmentCategoryOverride {
        guard AttachmentCategorySQL.isValid(value) else { throw MailPreferencesError.invalidRecord }
        return try await writer.write { db in
            try MailPreferencesSQL.requireAccount(value.accountID, db: db)
            let revision = try Int64.fetchOne(db, sql: """
                INSERT INTO attachmentCategoryOverride (accountID,messageID,partID,category,revision) VALUES (?,?,?,?,1)
                ON CONFLICT(accountID,messageID,partID) DO UPDATE SET category=excluded.category,revision=revision+1
                RETURNING revision
                """, arguments: [value.accountID, value.messageID, value.partID, value.category.rawValue])
            guard let revision else { throw MailPreferencesError.invalidRecord }
            var saved = value
            saved.revision = revision
            return saved
        }
    }

    /// Imports legacy cache choices without replacing later edits, including an explicit Uncategorized choice.
    public func importAttachmentCategoryOverrides(_ overrides: [AttachmentCategoryOverride]) async throws {
        guard overrides.allSatisfy(AttachmentCategorySQL.isValid) else { throw MailPreferencesError.invalidRecord }
        try await writer.write { db in
            let accounts = try String.fetchSet(db, sql: "SELECT id FROM account")
            for value in overrides where accounts.contains(value.accountID) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO attachmentCategoryOverride (accountID,messageID,partID,category,revision) VALUES (?,?,?,?,1)
                    """, arguments: [value.accountID, value.messageID, value.partID, value.category.rawValue])
            }
        }
    }
}

extension MailCache {
    public func attachmentCategorySnapshot(accountID: String? = nil) async throws -> [AttachmentCategoryOverride] {
        try await read { tx in
            var sql = "SELECT accountID,messageID,partID,category,0 AS revision FROM attachmentLibrary WHERE categorySource = ?"
            var arguments: StatementArguments = [AttachmentCategorySource.manual.rawValue]
            if let accountID { sql += " AND accountID = ?"; arguments += [accountID] }
            sql += " ORDER BY accountID,messageID,partID"
            return try Row.fetchAll(tx.db, sql: sql, arguments: arguments).map(AttachmentCategorySQL.record)
        }
    }

    public func applyAttachmentCategoryOverrides(_ overrides: [AttachmentCategoryOverride]) async throws {
        try await write { try $0.applyAttachmentCategoryOverrides(overrides) }
    }
}

extension CacheTransaction {
    public func applyAttachmentCategoryOverrides(_ overrides: [AttachmentCategoryOverride]) throws {
        guard overrides.allSatisfy({ AttachmentCategorySQL.isValid($0) && $0.revision > 0 }) else { throw MailPreferencesError.invalidRecord }
        for value in overrides {
            guard try libraryAttachment(accountID: value.accountID, messageID: value.messageID, partID: value.partID) != nil else { continue }
            let arguments: StatementArguments = [value.accountID, value.messageID, value.partID]
            let current = try Int64.fetchOne(db, sql: "SELECT revision FROM attachmentCategoryRevision WHERE accountID = ? AND messageID = ? AND partID = ?", arguments: arguments) ?? 0
            guard value.revision >= current else { continue }
            try setAttachmentCategory(value.category, accountID: value.accountID, messageID: value.messageID, partID: value.partID)
            try db.execute(sql: """
                INSERT INTO attachmentCategoryRevision (accountID,messageID,partID,revision) VALUES (?,?,?,?)
                ON CONFLICT(accountID,messageID,partID) DO UPDATE SET revision=excluded.revision
                """, arguments: [value.accountID, value.messageID, value.partID, value.revision])
        }
    }
}

enum AttachmentCategorySQL {
    static func isValid(_ value: AttachmentCategoryOverride) -> Bool {
        !value.accountID.isEmpty && !value.messageID.isEmpty && !value.partID.isEmpty
    }

    static func record(_ row: Row) throws -> AttachmentCategoryOverride {
        let name: String = row["category"]
        guard let category = AttachmentCategory(rawValue: name) else { throw MailPreferencesError.invalidRecord }
        return AttachmentCategoryOverride(accountID: row["accountID"], messageID: row["messageID"], partID: row["partID"], category: category, revision: row["revision"])
    }
}
