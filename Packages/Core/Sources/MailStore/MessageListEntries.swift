import Foundation
import GRDB
import MessageContent

/// Body-free list data with each message's effective labels and file metadata.
public struct MessageListEntry: Sendable, Equatable {
    public let message: MessageRecord
    public let labels: Set<String>
    public let attachments: [AttachmentRecord]
    public let snoozeWakeAt: Date?

    public init(message: MessageRecord, labels: Set<String>, attachments: [AttachmentRecord] = [], snoozeWakeAt: Date? = nil) {
        self.message = message
        self.labels = labels
        self.attachments = attachments
        self.snoozeWakeAt = snoozeWakeAt
    }

    public var rowThread: ThreadRecord {
        ThreadRecord(accountID: message.accountID, id: message.threadID, lastDate: message.date,
            subject: message.subject, snippet: message.snippet, participants: message.sender,
            messageCount: 1, isUnread: labels.contains(SystemLabel.unread), isStarred: labels.contains(SystemLabel.starred))
    }
}

extension MailCache {
    /// Uses account-qualified conversation IDs; repeated Gmail IDs never share rows.
    public func messageListEntries(threadsByAccount: [String: [String]], matching query: SearchQuery? = nil,
                                   includingMessageIDs: [String: Set<String>] = [:], snoozedOnly: Bool = false) -> AsyncThrowingStream<[MessageListEntry], any Error> {
        observe { db in
            let transaction = CacheTransaction(db: db)
            var entries: [MessageListEntry] = []
            for accountID in threadsByAccount.keys.sorted() {
                let snoozedThreads = snoozedOnly ? try transaction.snoozeHolds(accountID: accountID) : [:]
                let messageHolds = snoozedOnly ? try transaction.messageSnoozeHolds(accountID: accountID) : []
                let snoozedMessages = Dictionary(messageHolds.map { ($0.messageID, $0.wakeAt) }, uniquingKeysWith: min)
                var matchingIDs: Set<String>?
                if let query {
                    var matched = includingMessageIDs[accountID] ?? []
                    if query.runsLocally, let root = query.root {
                        var names: [String: [String]] = [:]
                        for label in try transaction.labels(accountID: accountID) {
                            names[SearchCompiler.normalizedLabelName(label.name), default: []].append(label.id)
                        }
                        var compiler = SearchCompiler(labelIDs: names, timeZone: .current, now: .now)
                        let predicate = compiler.sql(root)
                        var sql = "SELECT m.id FROM message m JOIN messageText mt ON mt.accountID=m.accountID AND mt.messageID=m.id WHERE m.accountID=? AND \(predicate)"
                        var arguments: StatementArguments = [accountID]
                        arguments += compiler.arguments
                        if !query.includesSpamAndTrash {
                            sql += " AND NOT EXISTS(SELECT 1 FROM messageLabel x WHERE x.accountID=m.accountID AND x.messageID=m.id AND x.labelID IN (?,?))"
                            arguments += [SystemLabel.spam, SystemLabel.trash]
                        }
                        matched.formUnion(try String.fetchSet(db, sql: sql, arguments: arguments))
                    }
                    matchingIDs = matched
                }
                let actions = try transaction.pendingActions(accountID: accountID)
                let hidden = try transaction.hiddenDraftMessageIDs(accountID: accountID)
                let fetched = try MessageListSQL.fetch(accountID: accountID, threadIDs: Set(threadsByAccount[accountID] ?? []), db: db)
                for (threadID, messages) in Dictionary(grouping: fetched.messages, by: \.threadID) {
                    var labels = Dictionary(messages.map { ($0.id, fetched.labels[$0.id] ?? []) }, uniquingKeysWith: { first, _ in first })
                    ThreadRules.overlay(actions, onto: &labels, threadID: threadID)
                    for message in messages where !hidden.contains(message.id) {
                        guard matchingIDs?.contains(message.id) ?? true else { continue }
                        if snoozedOnly, snoozedThreads[threadID] == nil, snoozedMessages[message.id] == nil { continue }
                        entries.append(MessageListEntry(message: message, labels: labels[message.id] ?? [],
                            attachments: fetched.attachments[message.id] ?? [],
                            snoozeWakeAt: snoozedMessages[message.id] ?? snoozedThreads[threadID]))
                    }
                }
            }
            return entries.sorted { lhs, rhs in
                if lhs.message.date != rhs.message.date { return lhs.message.date > rhs.message.date }
                return (lhs.message.accountID, lhs.message.id) < (rhs.message.accountID, rhs.message.id)
            }
        }
    }
}

private enum MessageListSQL {
    struct Fetched {
        var messages: [MessageRecord] = []
        var labels: [String: Set<String>] = [:]
        var attachments: [String: [AttachmentRecord]] = [:]
    }

    /// Three metadata reads per chunk, rather than reads for every list row.
    static func fetch(accountID: String, threadIDs: Set<String>, db: Database) throws -> Fetched {
        let ids = threadIDs.sorted()
        var result = Fetched()
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let arguments = StatementArguments([accountID] + chunk)
            let predicate = "m.accountID=? AND m.threadID IN (\(placeholders))"
            result.messages += try MessageRecord.fetchAll(db, sql: "SELECT m.* FROM message m WHERE \(predicate)", arguments: arguments)
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS messageID,l.labelID FROM message m
                LEFT JOIN messageLabel l ON l.accountID=m.accountID AND l.messageID=m.id
                WHERE \(predicate)
                """, arguments: arguments)
            for row in rows {
                let id: String = row["messageID"]
                if let label: String = row["labelID"] { result.labels[id, default: []].insert(label) }
            }
            let attachments = try AttachmentRecord.fetchAll(db, sql: """
                SELECT a.* FROM attachment a JOIN message m ON m.accountID=a.accountID AND m.id=a.messageID
                WHERE \(predicate) ORDER BY a.messageID,a.partID
                """, arguments: arguments)
            for attachment in attachments { result.attachments[attachment.messageID, default: []].append(attachment) }
        }
        return result
    }
}
