import Foundation
import GmailAPI
import MailStore

/// Notification candidates come only from committed history `messagesAdded`,
/// never from metadata history IDs, which also change when labels change.
public struct MailNotificationMessage: Sendable, Equatable {
    public var record: MessageRecord
    public var labelIDs: Set<String>
    public var addedHistoryID: Int64
    public init(record: MessageRecord, labelIDs: Set<String>, addedHistoryID: Int64) {
        self.record = record; self.labelIDs = labelIDs; self.addedHistoryID = addedHistoryID
    }
}

public struct MailSyncNotification: Sendable, Equatable {
    public var accountID: String
    public var fromHistoryID: Int64?
    public var toHistoryID: Int64
    public var messages: [MailNotificationMessage]
    public init(accountID: String, fromHistoryID: Int64?, toHistoryID: Int64, messages: [MailNotificationMessage] = []) {
        self.accountID = accountID; self.fromHistoryID = fromHistoryID; self.toHistoryID = toHistoryID; self.messages = messages
    }

    static func addedMessageHistory(_ records: [HistoryRecord]) -> [String: Int64] {
        var added: [String: Int64] = [:]
        for record in records {
            guard let historyID = Int64(record.id), historyID > 0 else { continue }
            for change in record.messagesAdded ?? [] {
                added[change.message.id] = max(added[change.message.id] ?? 0, historyID)
            }
        }
        return added
    }
}

extension SyncEngine {
    func publishMailNotification(from cursor: Int64?, to historyID: Int64, added: [String: Int64] = [:]) async {
        guard !isStopped, !Task.isCancelled else { return }
        let accountID = accountID
        do {
            let messages: [MailNotificationMessage] = try await cache.read { tx in
                try added.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }).compactMap { id, addedAt in
                    guard let message = try tx.message(id: id, accountID: accountID) else { return nil }
                    let labels = try tx.currentLabels(threadID: message.threadID, accountID: accountID)[id] ?? []
                    return MailNotificationMessage(record: message, labelIDs: labels, addedHistoryID: addedAt)
                }
            }
            guard !isStopped, !Task.isCancelled else { return }
            mailNotificationContinuation.yield(MailSyncNotification(accountID: accountID, fromHistoryID: cursor,
                toHistoryID: historyID, messages: messages))
        } catch {
            // No complete snapshot means no delivery event. The next event's
            // cursor gap establishes a quiet baseline instead of guessing.
        }
    }
}
