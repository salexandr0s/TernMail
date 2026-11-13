import Foundation
import GRDB

/// Custom labels on the visible messages of one conversation.
public struct ThreadLabels: Sendable, Equatable {
    public let accountID: String
    public let threadID: String
    public let labels: [LabelRecord]
}

extension MailCache {
    /// Observes labels for a list of conversations in one batch. Names, colors
    /// and membership include queued changes, just as the conversation reader does.
    public func threadLabels(
        threadsByAccount: [String: [String]]
    ) -> AsyncThrowingStream<[ThreadLabels], any Error> {
        let accountIDs = threadsByAccount.keys.sorted().filter { threadsByAccount[$0]?.isEmpty == false }
        let targets = accountIDs.flatMap { accountID in
            Set(threadsByAccount[accountID] ?? []).sorted().map { (accountID: accountID, threadID: $0) }
        }
        return observe(region: ObservedTables.threadLabels) { db in
            try CacheTransaction(db: db).threadLabels(of: targets, accountIDs: accountIDs)
        }
    }
}

extension CacheTransaction {
    /// What `MailCache.threadLabels(threadsByAccount:)` observes: the labels
    /// of `targets`, whose accounts are `accountIDs`.
    func threadLabels(
        of targets: [(accountID: String, threadID: String)], accountIDs: [String]
    ) throws -> [ThreadLabels] {
        guard !targets.isEmpty else { return [] }
        var displayed: [String: [LabelRecord]] = [:]
        var actions: [String: [PendingAction]] = [:]
        var hidden: [String: Set<String>] = [:]
        for accountID in accountIDs {
            displayed[accountID] = try displayedLabels(accountID: accountID).filter { !$0.isSystem }
            actions[accountID] = try pendingActions(accountID: accountID)
            hidden[accountID] = try hiddenDraftMessageIDs(accountID: accountID)
        }

        // Account, thread, message, then its labels. Keep unlabeled messages
        // too: a queued action may add their first custom label.
        var messages: [String: [String: [String: Set<String>]]] = [:]
        // Two parameters per conversation, below SQLite's smaller limits.
        for start in stride(from: 0, to: targets.count, by: 400) {
            let chunk = targets[start..<min(start + 400, targets.count)]
            let placeholders = Array(repeating: "(?, ?)", count: chunk.count).joined(separator: ", ")
            let arguments = StatementArguments(chunk.flatMap { [$0.accountID, $0.threadID] })
            let rows = try Row.fetchAll(db, sql: """
                SELECT message.accountID, message.threadID, message.id AS messageID, messageLabel.labelID
                FROM message
                LEFT JOIN messageLabel ON messageLabel.accountID = message.accountID
                    AND messageLabel.messageID = message.id
                WHERE (message.accountID, message.threadID) IN (VALUES \(placeholders))
                """, arguments: arguments)
            for row in rows {
                let accountID: String = row["accountID"]
                let threadID: String = row["threadID"]
                let messageID: String = row["messageID"]
                let labelID: String? = row["labelID"]
                guard hidden[accountID]?.contains(messageID) != true else { continue }
                messages[accountID, default: [:]][threadID, default: [:]][messageID, default: []]
                    .formUnion(labelID.map { [$0] } ?? [])
            }
        }

        return targets.map { target in
            var effective = messages[target.accountID]?[target.threadID] ?? [:]
            ThreadRules.overlay(actions[target.accountID] ?? [], onto: &effective, threadID: target.threadID)
            let applied = effective.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            return ThreadLabels(
                accountID: target.accountID, threadID: target.threadID,
                labels: (displayed[target.accountID] ?? []).filter { applied.contains($0.id) }
            )
        }
    }
}
