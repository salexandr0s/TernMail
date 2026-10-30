import Foundation
import GRDB

/// References only. Message text remains in the disposable mail cache.
public struct PendingMailAlert: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mailPendingAlert"
    public var accountID: String
    public var messageID: String
    public var threadID: String
    public var addedHistoryID: Int64
    public init(accountID: String, messageID: String, threadID: String, addedHistoryID: Int64) {
        self.accountID = accountID; self.messageID = messageID; self.threadID = threadID; self.addedHistoryID = addedHistoryID
    }
}

extension AccountStore {
    /// Processing progress and its exact pending deliveries commit together.
    @discardableResult
    public func enqueueMailAlerts(accountID: String, expectedHistoryID: Int64, to historyID: Int64,
                                  alerts: [PendingMailAlert]) async throws -> Bool {
        guard expectedHistoryID > 0, historyID >= expectedHistoryID,
              alerts.allSatisfy({ $0.accountID == accountID && !$0.messageID.isEmpty && !$0.threadID.isEmpty
                  && $0.addedHistoryID > expectedHistoryID && $0.addedHistoryID <= historyID }) else { throw MailPreferencesError.invalidRecord }
        return try await writer.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.id == accountID else { throw MailPreferencesError.accountMissing }
            let mark = try Int64.fetchOne(db, sql: "SELECT historyID FROM mailAlertWatermark WHERE accountID = ?", arguments: [accountID])
            guard mark == expectedHistoryID else { return false }
            for alert in alerts { try alert.insert(db, onConflict: .ignore) }
            try db.execute(sql: "UPDATE mailAlertWatermark SET historyID = ? WHERE accountID = ? AND historyID = ?",
                arguments: [historyID, accountID, expectedHistoryID])
            return db.changesCount == 1
        }
    }

    public func pendingMailAlerts(accountID: String? = nil) async throws -> [PendingMailAlert] {
        try await writer.read { db in
            if let accountID {
                return try PendingMailAlert.filter(Column("accountID") == accountID)
                    .order(Column("addedHistoryID"), Column("messageID")).fetchAll(db)
            }
            return try PendingMailAlert.order(Column("accountID"), Column("addedHistoryID"), Column("messageID")).fetchAll(db)
        }
    }

    public func removePendingMailAlert(accountID: String, messageID: String) async throws {
        try await writer.write { db in
            _ = try PendingMailAlert.deleteOne(db, key: ["accountID": accountID, "messageID": messageID])
        }
    }

    /// Explicit first-sync/reset/resume baselines discard old delivery intents.
    public func resetMailAlertDeliveryBaseline(accountID: String, historyID: Int64, at date: Date) async throws {
        guard historyID > 0 else { throw MailPreferencesError.invalidRecord }
        try await writer.write { db in
            guard try AccountRecord.fetchOne(db, key: accountID) != nil else { throw MailPreferencesError.accountMissing }
            try db.execute(sql: """
                INSERT INTO mailAlertWatermark(accountID,historyID,baselineAt) VALUES (?,?,?)
                ON CONFLICT(accountID) DO UPDATE SET historyID = MAX(historyID,excluded.historyID), baselineAt = excluded.baselineAt
                """, arguments: [accountID, historyID, date])
            _ = try PendingMailAlert.filter(Column("accountID") == accountID).deleteAll(db)
        }
    }
}
