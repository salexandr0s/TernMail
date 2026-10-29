import Foundation
import GRDB

/// Why Tern keeps a conversation in the cache that full sync wouldn't list.
public enum CacheHoldReason: String, Sendable {
    /// Gmail returned it for a search or a "Load older" page.
    case search
    /// It's snoozed and needs to be at hand when it wakes.
    case snooze
}

public enum CacheHolds {
    /// How long a search result stays after the last Gmail page that returned it.
    public static let searchLifetime: TimeInterval = 24 * 60 * 60
    /// Full sync lists mail this many days old (`newer_than:30d`), so a released
    /// conversation with newer mail would only be fetched again.
    public static let recentDays = 30
}

extension CacheTransaction {
    /// Holds conversations Gmail returned for a search until `expiresAt`. Write
    /// it in the transaction that stores their messages, so no prune runs in
    /// between. A hold's expiry only moves forward.
    public func holdSearchResults(_ threadIDs: some Collection<String>, until expiresAt: Date, accountID: String) throws {
        for threadID in Set(threadIDs) {
            try db.execute(sql: """
                INSERT INTO cacheHold (accountID, threadID, reason, expiresAt) VALUES (?, ?, ?, ?)
                ON CONFLICT (accountID, threadID, reason) DO UPDATE SET expiresAt = max(expiresAt, excluded.expiresAt)
                """, arguments: [accountID, threadID, CacheHoldReason.search.rawValue, expiresAt])
        }
    }

    /// Conversations with a hold of any reason, expired or not.
    public func heldThreadIDs(accountID: String) throws -> Set<String> {
        try String.fetchSet(db, sql: "SELECT DISTINCT threadID FROM cacheHold WHERE accountID = ?", arguments: [accountID])
    }

    /// Cached messages in held conversations, which full sync's prune keeps.
    func messageIDsInHeldThreads(accountID: String) throws -> Set<String> {
        try String.fetchSet(db, sql: """
            SELECT message.id FROM message
            JOIN cacheHold ON cacheHold.accountID = message.accountID AND cacheHold.threadID = message.threadID
            WHERE message.accountID = ?
            """, arguments: [accountID])
    }

    /// Ends search holds that expired by `now`, except for conversations in
    /// `visible` (an open search or list), and deletes the messages of the
    /// released conversations nothing else keeps. Returns the thread IDs to
    /// rebuild.
    ///
    /// A conversation stays when full sync would keep it (Inbox, Drafts, mail
    /// from the last 30 days), or it has a queued change, a local draft or
    /// another hold. These are checked here, in the write that deletes.
    public func releaseExpiredHolds(now: Date, keeping visible: Set<String>, accountID: String) throws -> Set<String> {
        let expired = try String.fetchSet(db, sql: """
            SELECT threadID FROM cacheHold WHERE accountID = ? AND reason = ? AND expiresAt <= ?
            """, arguments: [accountID, CacheHoldReason.search.rawValue, now])
            .subtracting(visible)
        guard !expired.isEmpty else { return [] }
        let threads = Array(expired)
        try db.execute(
            sql: "DELETE FROM cacheHold WHERE accountID = ? AND reason = ? AND threadID IN (\(databaseQuestionMarks(count: threads.count)))",
            arguments: [accountID, CacheHoldReason.search.rawValue] + StatementArguments(threads)
        )

        let released = expired.subtracting(try keptThreadIDs(among: threads, now: now, accountID: accountID))
        guard !released.isEmpty else { return [] }
        let messageIDs = try String.fetchAll(
            db,
            MessageRecord.select(Column("id"))
                .filter(Column("accountID") == accountID && released.contains(Column("threadID")))
        )
        return try deleteMessages(ids: messageIDs, accountID: accountID)
    }

    /// Which of `threadIDs` something other than a search hold keeps.
    private func keptThreadIDs(among threadIDs: [String], now: Date, accountID: String) throws -> Set<String> {
        let recent = now.addingTimeInterval(-Double(CacheHolds.recentDays) * 24 * 60 * 60)
        // What full sync lists.
        var kept = try String.fetchSet(db, sql: """
            SELECT message.threadID FROM message
            WHERE message.accountID = ? AND message.threadID IN (\(databaseQuestionMarks(count: threadIDs.count)))
                AND (message.date >= ? OR EXISTS (
                    SELECT 1 FROM messageLabel
                    WHERE messageLabel.accountID = message.accountID AND messageLabel.messageID = message.id
                        AND messageLabel.labelID IN (?, ?)))
            """, arguments: [accountID] + StatementArguments(threadIDs) + [recent, SystemLabel.inbox, SystemLabel.draft])

        kept.formUnion(try heldThreadIDs(accountID: accountID))
        kept.formUnion(try String.fetchSet(db, sql: """
            SELECT threadID FROM localDraft WHERE accountID = ? AND threadID IS NOT NULL
            UNION
            SELECT message.threadID FROM localDraft
            JOIN message ON message.accountID = localDraft.accountID
                AND message.id IN (localDraft.sourceMessageID, localDraft.savedMessageID)
            WHERE localDraft.accountID = ?
            """, arguments: [accountID, accountID]))

        let actions = try pendingActions(accountID: accountID)
        kept.formUnion(actions.flatMap(\.threadIDs))
        kept.formUnion(try threadIDsOf(messageIDs: actions.flatMap(\.messageIDs), accountID: accountID))
        return kept.intersection(threadIDs)
    }
}
