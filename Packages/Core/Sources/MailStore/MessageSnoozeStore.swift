import Foundation
import GRDB

public struct MessageSnoozeRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messageSnooze"
    public var accountID: String
    public var messageID: String
    public var threadID: String
    public var wakeAt: Date
    public var createdAt: Date
    public var revision: String

    public init(accountID: String, messageID: String, threadID: String, wakeAt: Date, createdAt: Date, revision: String = UUID().uuidString) {
        self.accountID = accountID; self.messageID = messageID; self.threadID = threadID
        self.wakeAt = wakeAt; self.createdAt = createdAt; self.revision = revision
    }
}

enum MessageSnoozeSchema {
    static func registerConfig(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("message-snooze-config-v1") { db in
            try db.create(table: "messageSnooze") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("messageID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("wakeAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["accountID", "messageID"])
            }
        }
        migrator.registerMigration("message-snooze-config-revisions-v1") { db in
            try db.alter(table: "messageSnooze") { t in
                t.add(column: "revision", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE messageSnooze SET revision = lower(hex(randomblob(16)))")
        }
    }

    static func registerCache(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("message-snooze-cache-v1") { db in
            try db.create(table: "messageSnoozeHold") { t in
                t.column("accountID", .text).notNull()
                t.column("messageID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("wakeAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["accountID", "messageID"])
                t.foreignKey(["accountID", "messageID"], references: "message", onDelete: .cascade)
            }
        }
        migrator.registerMigration("message-snooze-cache-revisions-v1") { db in
            try db.alter(table: "messageSnoozeHold") { t in
                t.add(column: "revision", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE messageSnoozeHold SET revision = lower(hex(randomblob(16)))")
        }
    }
}

extension CacheTransaction {
    public func messageSnoozeHolds(accountID: String) throws -> [MessageSnoozeRecord] {
        try MessageSnoozeRecord.fetchAll(db, sql: "SELECT * FROM messageSnoozeHold WHERE accountID = ? ORDER BY wakeAt, messageID", arguments: [accountID])
    }

    public func holdMessageSnooze(_ record: MessageSnoozeRecord) throws {
        guard try message(id: record.messageID, accountID: record.accountID)?.threadID == record.threadID else { return }
        try db.execute(sql: """
            INSERT INTO messageSnoozeHold(accountID,messageID,threadID,wakeAt,createdAt,revision) VALUES (?,?,?,?,?,?)
            ON CONFLICT(accountID,messageID) DO UPDATE SET threadID=excluded.threadID,wakeAt=excluded.wakeAt,createdAt=excluded.createdAt,revision=excluded.revision
            """, arguments: [record.accountID, record.messageID, record.threadID, record.wakeAt, record.createdAt, record.revision])
    }

    @discardableResult
    public func releaseMessageSnooze(messageID: String, wakingAt: Date? = nil, revision: String? = nil, accountID: String) throws -> Bool {
        var sql = "DELETE FROM messageSnoozeHold WHERE accountID=? AND messageID=?"
        var arguments: StatementArguments = [accountID, messageID]
        if let wakingAt { sql += " AND wakeAt=?"; arguments += [wakingAt] }
        if let revision { sql += " AND revision=?"; arguments += [revision] }
        try db.execute(sql: sql, arguments: arguments)
        return db.changesCount > 0
    }
}

extension AccountStore {
    public func messageSnoozes(accountID: String) async throws -> [MessageSnoozeRecord] {
        try await writer.read { db in
            try MessageSnoozeRecord.filter(Column("accountID") == accountID).order(Column("wakeAt"), Column("messageID")).fetchAll(db)
        }
    }

    /// One config transaction preserves legacy intent until every split member is durable.
    public func applyMessageSnoozes(_ records: [MessageSnoozeRecord], replacingThreads: [String: Date], accountID: String) async throws {
        try await writer.write { db in
            for record in records where record.accountID == accountID { try record.upsert(db) }
            for (threadID, wakeAt) in replacingThreads {
                _ = try SnoozeRecord.filter(Column("accountID") == accountID && Column("threadID") == threadID && Column("wakeAt") == wakeAt).deleteAll(db)
            }
        }
    }

    public func applyThreadSnoozes(_ records: [SnoozeRecord], removingMessages: [MessageSnoozeRecord], accountID: String) async throws {
        try await writer.write { db in
            for record in records where record.accountID == accountID { try record.upsert(db) }
            for record in removingMessages where record.accountID == accountID {
                _ = try MessageSnoozeRecord.filter(Column("accountID") == accountID && Column("messageID") == record.messageID && Column("revision") == record.revision).deleteAll(db)
            }
        }
    }

    public func deleteMessageSnoozes(_ records: [MessageSnoozeRecord], accountID: String) async throws {
        try await writer.write { db in
            for record in records where record.accountID == accountID {
                _ = try MessageSnoozeRecord.filter(Column("accountID") == accountID && Column("messageID") == record.messageID && Column("revision") == record.revision).deleteAll(db)
            }
        }
    }

    /// Commits either kind of snooze and its replaced records together. A failed
    /// config write keeps the older durable intent for the next reconciliation.
    public func applySnoozeChanges(threads: [SnoozeRecord] = [], messages: [MessageSnoozeRecord] = [],
                                   removingThreads: [String: Date] = [:], removingMessages: [MessageSnoozeRecord] = [],
                                   accountID: String) async throws {
        try await writer.write { db in
            for (threadID, wakeAt) in removingThreads {
                _ = try SnoozeRecord.filter(Column("accountID") == accountID && Column("threadID") == threadID && Column("wakeAt") == wakeAt).deleteAll(db)
            }
            for record in removingMessages where record.accountID == accountID {
                _ = try MessageSnoozeRecord.filter(Column("accountID") == accountID && Column("messageID") == record.messageID && Column("revision") == record.revision).deleteAll(db)
            }
            for record in threads where record.accountID == accountID { try record.upsert(db) }
            for record in messages where record.accountID == accountID { try record.upsert(db) }
        }
    }
}
