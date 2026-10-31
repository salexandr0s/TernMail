import Foundation
import GRDB

/// A label's unread counts as the sidebar shows them: Gmail's last counts
/// with the local changes it hasn't counted yet applied, so a badge moves
/// with the list instead of a pass later.
public struct LabelCounts: Sendable, Equatable {
    /// Unread conversations. Nil until Gmail has counted the label.
    public var threadsUnread: Int?
    /// Unread messages. Nil until Gmail has counted the label.
    public var messagesUnread: Int?
    /// Whether the counts include a change Gmail hasn't counted yet.
    public var includesLocalChanges: Bool

    public init(threadsUnread: Int?, messagesUnread: Int?, includesLocalChanges: Bool) {
        self.threadsUnread = threadsUnread
        self.messagesUnread = messagesUnread
        self.includesLocalChanges = includesLocalChanges
    }
}

extension MailCache {
    /// Unread counts for every label Gmail listed, by label ID. A queued
    /// change moves them in the same write that moves the list.
    public func unreadCounts(accountID: String) -> AsyncThrowingStream<[String: LabelCounts], any Error> {
        observe { db in try CacheTransaction(db: db).unreadCounts(accountID: accountID) }
    }
}

/// How unread counts follow local changes. A change records in `unreadDelta`,
/// per label, how many conversations and messages it made unread (positive)
/// or read (negative) as the list shows them. The rows are added to Gmail's
/// counts until a label refresh counted after Gmail accepted the change.
/// They outlive the change's queue row: a pass drops that row once Gmail's
/// history of the change arrives, which is before the refresh that follows.
extension CacheTransaction {
    public func unreadCounts(accountID: String) throws -> [String: LabelCounts] {
        var deltas: [String: (threads: Int, messages: Int)] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT labelID, SUM(threads) AS threads, SUM(messages) AS messages
            FROM unreadDelta WHERE accountID = ? GROUP BY labelID
            """, arguments: [accountID])
        for row in rows {
            let labelID: String = row["labelID"]
            deltas[labelID] = (row["threads"], row["messages"])
        }
        var counts: [String: LabelCounts] = [:]
        for label in try labels(accountID: accountID) {
            let delta = deltas[label.id]
            counts[label.id] = LabelCounts(
                threadsUnread: label.threadsUnread.map { max(0, $0 + (delta?.threads ?? 0)) },
                messagesUnread: label.messagesUnread.map { max(0, $0 + (delta?.messages ?? 0)) },
                includesLocalChanges: delta != nil
            )
        }
        return counts
    }

    /// Rebuilds `threadIDs` and records how `action` moved their unread
    /// counts: the difference between their effective labels before and
    /// after, read by the rules the list marks conversations with. Only
    /// labels Gmail listed get a row, since only their counts are shown.
    func rebuildThreads(_ threadIDs: Set<String>, countingUnreadChangesOf action: PendingAction) throws {
        let accountID = action.accountID
        let before = try Dictionary(uniqueKeysWithValues: threadIDs.map { threadID in
            (threadID, try storedEffectiveLabels(threadID: threadID, accountID: accountID))
        })
        try rebuildThreads(threadIDs, accountID: accountID)
        guard let actionID = action.id else { return }
        try forgetUnsentUnreadDeltas(actionID: actionID, accountID: accountID)

        let hidden = try hiddenDraftMessageIDs(accountID: accountID)
        let shown = { (labels: [String: Set<String>]) in labels.filter { !hidden.contains($0.key) }.map(\.value) }
        var threads: [String: Int] = [:]
        var messages: [String: Int] = [:]
        for (threadID, old) in before {
            let was = shown(old)
            let now = shown(try storedEffectiveLabels(threadID: threadID, accountID: accountID))
            let wasUnread = ThreadRules.unreadLabels(messageLabels: was)
            let isUnread = ThreadRules.unreadLabels(messageLabels: now)
            for labelID in isUnread.subtracting(wasUnread) { threads[labelID, default: 0] += 1 }
            for labelID in wasUnread.subtracting(isUnread) { threads[labelID, default: 0] -= 1 }
            for (labelID, count) in ThreadRules.unreadMessageCounts(messageLabels: now) { messages[labelID, default: 0] += count }
            for (labelID, count) in ThreadRules.unreadMessageCounts(messageLabels: was) { messages[labelID, default: 0] -= count }
        }
        let listed = try String.fetchSet(db, sql: "SELECT id FROM label WHERE accountID = ?", arguments: [accountID])
        for labelID in Set(threads.keys).union(messages.keys).intersection(listed).sorted() {
            let threadDelta = threads[labelID] ?? 0
            let messageDelta = messages[labelID] ?? 0
            guard threadDelta != 0 || messageDelta != 0 else { continue }
            try db.execute(
                sql: "INSERT INTO unreadDelta (accountID, actionID, labelID, threads, messages) VALUES (?, ?, ?, ?, ?)",
                arguments: [accountID, actionID, labelID, threadDelta, messageDelta]
            )
        }
    }

    /// Keeps a change's deltas in step with its state: once Gmail accepts
    /// the change they carry its send time, and a change undone or refused
    /// before then stops counting.
    func followUnreadDeltas(of action: PendingAction) throws {
        guard let actionID = action.id else { return }
        switch action.state {
        case .sent:
            guard let sentAt = action.sentAt else { return }
            try db.execute(
                sql: "UPDATE unreadDelta SET sentAt = ? WHERE accountID = ? AND actionID = ? AND sentAt IS NULL",
                arguments: [sentAt, action.accountID, actionID]
            )
        case .undone, .failed:
            try forgetUnsentUnreadDeltas(actionID: actionID, accountID: action.accountID)
        case .queued, .sending:
            break
        }
    }

    /// Removes the deltas of a change Gmail hasn't accepted, for when the
    /// change stops applying.
    func forgetUnsentUnreadDeltas(actionID: Int64, accountID: String) throws {
        try db.execute(
            sql: "DELETE FROM unreadDelta WHERE accountID = ? AND actionID = ? AND sentAt IS NULL",
            arguments: [accountID, actionID]
        )
    }

    /// Removes the deltas Gmail's counts now hold: those of changes it
    /// accepted by `countedAt`, for `labelIDs`, or for every label when nil.
    /// A full listing passes nil, which also clears labels deleted since.
    func settleUnreadDeltas(labelIDs: Set<String>?, countedAt: Date, accountID: String) throws {
        var arguments: StatementArguments = [accountID, countedAt]
        var sql = "DELETE FROM unreadDelta WHERE accountID = ? AND sentAt <= ?"
        if let labelIDs {
            guard !labelIDs.isEmpty else { return }
            sql += " AND labelID IN (\(databaseQuestionMarks(count: labelIDs.count)))"
            arguments += StatementArguments(labelIDs.sorted())
        }
        try db.execute(sql: sql, arguments: arguments)
    }

    /// Removes the deltas a quit or crash left for changes that never
    /// reached Gmail and no longer apply: deleted, refused or undone.
    func forgetStaleUnreadDeltas(accountID: String) throws {
        try db.execute(sql: """
            DELETE FROM unreadDelta
            WHERE accountID = ? AND sentAt IS NULL AND actionID NOT IN (
                SELECT id FROM pendingAction WHERE accountID = ? AND state IN (?, ?, ?)
            )
            """, arguments: [
                accountID, accountID,
                PendingAction.State.queued.rawValue, PendingAction.State.sending.rawValue, PendingAction.State.sent.rawValue,
            ])
    }
}

extension ThreadRules {
    /// The labels a conversation counts as unread under: every label it is
    /// listed under when any of its messages is unread, which is how the
    /// list marks it.
    static func unreadLabels(messageLabels: [Set<String>]) -> Set<String> {
        guard messageLabels.contains(where: { $0.contains(SystemLabel.unread) }) else { return [] }
        return threadLabels(messageLabels: messageLabels)
    }

    /// How many unread messages carry each label.
    static func unreadMessageCounts(messageLabels: [Set<String>]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for labels in messageLabels where labels.contains(SystemLabel.unread) {
            for labelID in labels { counts[labelID, default: 0] += 1 }
        }
        return counts
    }
}
