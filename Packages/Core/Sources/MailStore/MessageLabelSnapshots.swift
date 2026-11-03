import Foundation
import GRDB
import MessageContent

public struct MessageLabelSnapshot: Sendable {
    public let messageID: String
    public let threadID: String
    /// One normalized sender, or empty when the header cannot identify one.
    public let sender: String
    public let date: Date
    public let labelIDs: Set<String>
}

extension CacheTransaction {
    /// Reads metadata and labels in bounded queries for large reviewed selections.
    public func messageLabelSnapshots(messageIDs: [String], accountID: String,
                                      matchingLabelIDs: Set<String>? = nil) throws -> [String: MessageLabelSnapshot] {
        try messageLabelSnapshots(ids: messageIDs, column: "id", accountID: accountID, matchingLabelIDs: matchingLabelIDs)
    }

    public func messageLabelSnapshots(threadIDs: [String], accountID: String,
                                      matchingLabelIDs: Set<String>? = nil) throws -> [String: MessageLabelSnapshot] {
        try messageLabelSnapshots(ids: threadIDs, column: "threadID", accountID: accountID, matchingLabelIDs: matchingLabelIDs)
    }

    private func messageLabelSnapshots(ids: [String], column: String, accountID: String,
                                       matchingLabelIDs: Set<String>?) throws -> [String: MessageLabelSnapshot] {
        let targets = Array(Set(ids)).sorted()
        var result: [String: MessageLabelSnapshot] = [:]
        for start in stride(from: 0, to: targets.count, by: 900) {
            let chunk = Array(targets[start..<min(start + 900, targets.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let messages = try Row.fetchAll(db,
                sql: "SELECT id, threadID, sender, date FROM message WHERE accountID = ? AND \(column) IN (\(placeholders))",
                arguments: StatementArguments([accountID] + chunk))
            var labels: [String: Set<String>] = [:]
            let messageIDs: [String] = messages.map { $0["id"] }
            for offset in stride(from: 0, to: messageIDs.count, by: 900) {
                let selected = Array(messageIDs[offset..<min(offset + 900, messageIDs.count)])
                let marks = Array(repeating: "?", count: selected.count).joined(separator: ",")
                var sql = "SELECT messageID, labelID FROM messageLabel WHERE accountID = ? AND messageID IN (\(marks))"
                var arguments = [accountID] + selected
                if let matchingLabelIDs {
                    if matchingLabelIDs.isEmpty { continue }
                    let matching = matchingLabelIDs.sorted()
                    sql += " AND labelID IN (" + Array(repeating: "?", count: matching.count).joined(separator: ",") + ")"
                    arguments += matching
                }
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                for row in rows {
                    let messageID: String = row["messageID"]
                    let labelID: String = row["labelID"]
                    labels[messageID, default: []].insert(labelID)
                }
            }
            for message in messages {
                let id: String = message["id"]
                let senders = EmailAddress.parseList(message["sender"]).filter(\.isValid)
                let sender = senders.count == 1 ? senders[0].normalized : ""
                result[id] = .init(messageID: id, threadID: message["threadID"], sender: sender,
                                   date: message["date"], labelIDs: labels[id] ?? [])
            }
        }
        return result
    }
}
