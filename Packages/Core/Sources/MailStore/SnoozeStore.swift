import Foundation
import GRDB

/// The durable copy of a snooze in `config.sqlite`. The cache's snooze hold
/// is the working copy; this one outlives a cache reset.
public struct SnoozeRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "snooze"

    public var accountID: String
    public var threadID: String
    public var wakeAt: Date
    public var createdAt: Date

    public init(accountID: String, threadID: String, wakeAt: Date, createdAt: Date) {
        self.accountID = accountID
        self.threadID = threadID
        self.wakeAt = wakeAt
        self.createdAt = createdAt
    }
}

/// A snoozed conversation and when it comes back.
public struct SnoozedThread: Sendable, Equatable, Identifiable {
    public var thread: ThreadRecord
    public var wakeAt: Date

    public var id: String { thread.id }
}

extension CacheTransaction {
    /// Keeps a snoozed conversation in the cache until it wakes at `wakeAt`.
    /// Snoozing it again moves the time.
    public func holdSnooze(threadID: String, until wakeAt: Date, accountID: String) throws {
        try db.execute(sql: """
            INSERT INTO cacheHold (accountID, threadID, reason, wakeAt) VALUES (?, ?, ?, ?)
            ON CONFLICT (accountID, threadID, reason) DO UPDATE SET wakeAt = excluded.wakeAt
            """, arguments: [accountID, threadID, CacheHoldReason.snooze.rawValue, wakeAt])
    }

    /// Snoozed conversations and their wake times.
    public func snoozeHolds(accountID: String, wakingAt wakeAt: Date? = nil) throws -> [String: Date] {
        var sql = "SELECT threadID, wakeAt FROM cacheHold WHERE accountID = ? AND reason = ? AND wakeAt IS NOT NULL"
        var arguments: StatementArguments = [accountID, CacheHoldReason.snooze.rawValue]
        // Bind the original date just as releaseSnooze does: GRDB stores
        // milliseconds, while an Undo receipt can retain finer precision.
        if let wakeAt { sql += " AND wakeAt = ?"; arguments += [wakeAt] }
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        return Dictionary(rows.map { ($0["threadID"], $0["wakeAt"]) }, uniquingKeysWith: { first, _ in first })
    }

    /// Ends a snooze in the cache. The conversation stays where it is. With
    /// `wakeAt`, only a hold that still wakes then ends, so a snooze moved
    /// since stays. Returns whether a hold ended.
    @discardableResult
    public func releaseSnooze(threadID: String, wakingAt wakeAt: Date? = nil, accountID: String) throws -> Bool {
        var sql = "DELETE FROM cacheHold WHERE accountID = ? AND threadID = ? AND reason = ?"
        var arguments: StatementArguments = [accountID, threadID, CacheHoldReason.snooze.rawValue]
        if let wakeAt {
            sql += " AND wakeAt = ?"
            arguments += [wakeAt]
        }
        try db.execute(sql: sql, arguments: arguments)
        return db.changesCount > 0
    }

    /// Each cached message's labels in the conversation, with queued changes
    /// applied. Empty when the cache has none of its messages.
    public func currentLabels(threadID: String, accountID: String) throws -> [String: Set<String>] {
        try effectiveLabels(threadID: threadID, accountID: accountID, actions: try pendingActions(accountID: accountID))
    }

    /// Sorts a woken conversation by `wokeAt` until it leaves the Inbox. The
    /// list rows already written for it move at once; `rebuildThreads` keeps
    /// them there.
    public func recordWake(threadID: String, at wokeAt: Date, accountID: String) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO wokenThread (accountID, threadID, wokeAt) VALUES (?, ?, ?)",
            arguments: [accountID, threadID, wokeAt]
        )
        try db.execute(
            sql: "UPDATE threadLabel SET listDate = MAX(lastDate, ?) WHERE accountID = ? AND threadID = ?",
            arguments: [wokeAt, accountID, threadID]
        )
    }

    func forgetWake(threadID: String, accountID: String) throws {
        try db.execute(sql: "DELETE FROM wokenThread WHERE accountID = ? AND threadID = ?", arguments: [accountID, threadID])
        try db.execute(
            sql: "UPDATE threadLabel SET listDate = lastDate WHERE accountID = ? AND threadID = ?",
            arguments: [accountID, threadID]
        )
    }

    func wakeTime(threadID: String, accountID: String) throws -> Date? {
        try Date.fetchOne(
            db, sql: "SELECT wokeAt FROM wokenThread WHERE accountID = ? AND threadID = ?", arguments: [accountID, threadID]
        )
    }
}

extension MailCache {
    /// Snoozed conversations in the cache, the soonest to wake first.
    public func snoozedThreads(accountID: String) -> AsyncThrowingStream<[SnoozedThread], any Error> {
        observe { db in
            try Row.fetchAll(db, sql: """
                WITH holds AS (
                    SELECT accountID, threadID, wakeAt FROM cacheHold
                    WHERE accountID = ? AND reason = ? AND wakeAt IS NOT NULL
                    UNION ALL SELECT accountID, threadID, wakeAt FROM messageSnoozeHold WHERE accountID = ?
                ), grouped AS (
                    SELECT accountID,threadID,MIN(wakeAt) AS wakeAt FROM holds GROUP BY accountID,threadID
                )
                SELECT thread.*, grouped.wakeAt AS wakeAt FROM grouped
                JOIN thread ON thread.accountID=grouped.accountID AND thread.id=grouped.threadID
                ORDER BY grouped.wakeAt, thread.id
                """, arguments: [accountID, CacheHoldReason.snooze.rawValue, accountID])
            .map { row in SnoozedThread(thread: try ThreadRecord(row: row), wakeAt: row["wakeAt"]) }
        }
    }

    /// Conversations a snooze brought back that are still in the Inbox.
    public func wokenThreadIDs(accountID: String) -> AsyncThrowingStream<Set<String>, any Error> {
        observe { db in
            try String.fetchSet(db, sql: "SELECT threadID FROM wokenThread WHERE accountID = ?", arguments: [accountID])
        }
    }
}

extension AccountStore {
    public func snoozes(accountID: String) async throws -> [SnoozeRecord] {
        try await writer.read { db in
            try SnoozeRecord.filter(Column("accountID") == accountID).order(Column("wakeAt")).fetchAll(db)
        }
    }

    public func saveSnooze(_ snooze: SnoozeRecord) async throws {
        try await writer.write { db in try snooze.upsert(db) }
    }

    /// Deletes a snooze record. With `wakeAt`, only a record that still
    /// wakes then, so a snooze saved since stays.
    public func deleteSnooze(accountID: String, threadID: String, wakingAt wakeAt: Date? = nil) async throws {
        try await writer.write { db in
            var request = SnoozeRecord.filter(Column("accountID") == accountID && Column("threadID") == threadID)
            if let wakeAt { request = request.filter(Column("wakeAt") == wakeAt) }
            _ = try request.deleteAll(db)
        }
    }
}
