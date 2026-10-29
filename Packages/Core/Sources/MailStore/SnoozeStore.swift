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
    public func snoozeHolds(accountID: String) throws -> [String: Date] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT threadID, wakeAt FROM cacheHold WHERE accountID = ? AND reason = ? AND wakeAt IS NOT NULL
            """, arguments: [accountID, CacheHoldReason.snooze.rawValue])
        return Dictionary(rows.map { ($0["threadID"], $0["wakeAt"]) }, uniquingKeysWith: { first, _ in first })
    }

    /// Ends a snooze in the cache. The conversation stays where it is.
    public func releaseSnooze(threadID: String, accountID: String) throws {
        try db.execute(
            sql: "DELETE FROM cacheHold WHERE accountID = ? AND threadID = ? AND reason = ?",
            arguments: [accountID, threadID, CacheHoldReason.snooze.rawValue]
        )
    }

    /// Sorts a woken conversation by `wokeAt` until it leaves the Inbox.
    public func recordWake(threadID: String, at wokeAt: Date, accountID: String) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO wokenThread (accountID, threadID, wokeAt) VALUES (?, ?, ?)",
            arguments: [accountID, threadID, wokeAt]
        )
    }

    func forgetWake(threadID: String, accountID: String) throws {
        try db.execute(sql: "DELETE FROM wokenThread WHERE accountID = ? AND threadID = ?", arguments: [accountID, threadID])
    }
}

extension MailCache {
    /// Snoozed conversations in the cache, the soonest to wake first.
    public func snoozedThreads(accountID: String) -> AsyncThrowingStream<[SnoozedThread], any Error> {
        observe { db in
            try Row.fetchAll(db, sql: """
                SELECT thread.*, cacheHold.wakeAt AS wakeAt
                FROM cacheHold
                JOIN thread ON thread.accountID = cacheHold.accountID AND thread.id = cacheHold.threadID
                WHERE cacheHold.accountID = ? AND cacheHold.reason = ? AND cacheHold.wakeAt IS NOT NULL
                ORDER BY cacheHold.wakeAt, thread.id
                """, arguments: [accountID, CacheHoldReason.snooze.rawValue])
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

    public func deleteSnooze(accountID: String, threadID: String) async throws {
        try await writer.write { db in
            _ = try SnoozeRecord.deleteOne(db, key: ["accountID": accountID, "threadID": threadID])
        }
    }
}
