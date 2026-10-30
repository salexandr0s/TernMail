import Foundation
import GRDB
import MessageContent

extension AccountStore {
    public func mailPreferences(accountID: String) async throws -> AccountMailPreferences {
        try await writer.read { try MailPreferencesSQL.preferences(accountID: accountID, db: $0) }
    }

    public func allMailPreferences() async throws -> [AccountMailPreferences] {
        try await writer.read { try MailPreferencesSQL.allPreferences(db: $0) }
    }

    public func observeMailPreferences() -> AsyncThrowingStream<[AccountMailPreferences], any Error> {
        observeMailConfiguration { try MailPreferencesSQL.allPreferences(db: $0) }
    }

    @discardableResult
    public func updateMailPreferences(accountID: String,
        _ change: @escaping @Sendable (inout AccountMailPreferences) -> Void
    ) async throws -> AccountMailPreferences {
        try await writer.write { db in
            var value = try MailPreferencesSQL.preferences(accountID: accountID, db: db)
            change(&value)
            guard value.accountID == accountID else { throw MailPreferencesError.invalidRecord }
            if let profileID = value.profileID {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mailProfile WHERE id = ?)", arguments: [profileID]) == true else {
                    throw MailPreferencesError.missingReference
                }
            }
            value.nickname = value.nickname.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            try db.execute(sql: """
                INSERT INTO accountMailPreference (accountID,nickname,sortOrder,syncEnabled,profileID,inboxCategories,notificationRule)
                VALUES (?,?,?,?,?,?,?) ON CONFLICT(accountID) DO UPDATE SET
                nickname=excluded.nickname,sortOrder=excluded.sortOrder,syncEnabled=excluded.syncEnabled,
                profileID=excluded.profileID,inboxCategories=excluded.inboxCategories,notificationRule=excluded.notificationRule
                """, arguments: [accountID, value.nickname, value.sortOrder, value.syncEnabled, value.profileID,
                    try MailPreferencesSQL.encode(value.inboxCategories.map(\.rawValue).sorted()), value.notificationRule.rawValue])
            return value
        }
    }

    public func mailProfiles() async throws -> [MailProfile] {
        try await writer.read { try MailPreferencesSQL.profiles(db: $0) }
    }

    public func observeMailProfiles() -> AsyncThrowingStream<[MailProfile], any Error> {
        observeMailConfiguration { try MailPreferencesSQL.profiles(db: $0) }
    }

    public func saveMailProfile(_ profile: MailProfile) async throws {
        guard MailPreferencesSQL.nonblank(profile.id), MailPreferencesSQL.nonblank(profile.name),
              MailPreferencesSQL.nonblank(profile.symbol), profile.colorIndex >= 0, profile.notificationSchedule.isValid else {
            throw MailPreferencesError.invalidRecord
        }
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO mailProfile (id,name,colorIndex,symbol,sortOrder,schedule) VALUES (?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,colorIndex=excluded.colorIndex,symbol=excluded.symbol,
                sortOrder=excluded.sortOrder,schedule=excluded.schedule
                """, arguments: [profile.id, profile.name, profile.colorIndex, profile.symbol, profile.sortOrder,
                    try MailPreferencesSQL.encode(profile.notificationSchedule)])
        }
    }

    public func deleteMailProfile(id: String) async throws {
        try await writer.write { try $0.execute(sql: "DELETE FROM mailProfile WHERE id = ?", arguments: [id]) }
    }

    public func allowedImageSenders(accountID: String) async throws -> Set<String> {
        try await senderPreferences(table: "imageSenderAllow", accountID: accountID)
    }

    public func setImageSenderAllowed(_ allowed: Bool, address: String, accountID: String) async throws {
        try await setSenderPreference(allowed, table: "imageSenderAllow", address: address, accountID: accountID)
    }

    public func blockedSuggestionAddresses(accountID: String) async throws -> Set<String> {
        try await senderPreferences(table: "suggestionBlock", accountID: accountID)
    }

    public func setSuggestionBlocked(_ blocked: Bool, address: String, accountID: String) async throws {
        try await setSenderPreference(blocked, table: "suggestionBlock", address: address, accountID: accountID)
    }

    public func mailAlertWatermark(accountID: String) async throws -> MailAlertWatermark? {
        try await writer.read { db in
            try MailPreferencesSQL.requireAccount(accountID, db: db)
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM mailAlertWatermark WHERE accountID = ?", arguments: [accountID]) else { return nil }
            return MailAlertWatermark(accountID: accountID, historyID: row["historyID"], baselineAt: row["baselineAt"])
        }
    }

    public func setMailAlertBaseline(accountID: String, historyID: Int64, at date: Date) async throws {
        guard historyID > 0, date.timeIntervalSince1970.isFinite else { throw MailPreferencesError.invalidRecord }
        try await writer.write { db in
            try MailPreferencesSQL.requireAccount(accountID, db: db)
            try db.execute(sql: """
                INSERT INTO mailAlertWatermark (accountID,historyID,baselineAt) VALUES (?,?,?)
                ON CONFLICT(accountID) DO UPDATE SET historyID=excluded.historyID,baselineAt=excluded.baselineAt
                """, arguments: [accountID, historyID, date])
        }
    }

    @discardableResult
    public func advanceMailAlertWatermark(accountID: String, expectedHistoryID: Int64, to historyID: Int64) async throws -> Bool {
        guard expectedHistoryID > 0, historyID >= expectedHistoryID else { throw MailPreferencesError.invalidRecord }
        return try await writer.write { db in
            try MailPreferencesSQL.requireAccount(accountID, db: db)
            try db.execute(sql: "UPDATE mailAlertWatermark SET historyID = ? WHERE accountID = ? AND historyID = ?",
                arguments: [historyID, accountID, expectedHistoryID])
            return db.changesCount == 1
        }
    }

    private func senderPreferences(table: String, accountID: String) async throws -> Set<String> {
        try await writer.read { db in
            try MailPreferencesSQL.requireAccount(accountID, db: db)
            return try String.fetchSet(db, sql: "SELECT address FROM \(table) WHERE accountID = ?", arguments: [accountID])
        }
    }

    private func setSenderPreference(_ enabled: Bool, table: String, address: String, accountID: String) async throws {
        let address = EmailAddress(address: address)
        guard address.isValid else { throw MailPreferencesError.invalidRecord }
        try await writer.write { db in
            try MailPreferencesSQL.requireAccount(accountID, db: db)
            if enabled {
                try db.execute(sql: "INSERT OR IGNORE INTO \(table) (accountID,address) VALUES (?,?)", arguments: [accountID, address.normalized])
            } else {
                try db.execute(sql: "DELETE FROM \(table) WHERE accountID = ? AND address = ?", arguments: [accountID, address.normalized])
            }
        }
    }

    func observeMailConfiguration<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncThrowingStream<T, any Error> {
        let values = ValueObservation.tracking(fetch).values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum MailPreferencesSQL {
    static func nonblank(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(value.utf8))
    }

    static func requireAccount(_ accountID: String, db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM account WHERE id = ?)", arguments: [accountID]) == true else {
            throw MailPreferencesError.accountMissing
        }
    }

    static func preferences(accountID: String, db: Database) throws -> AccountMailPreferences {
        try requireAccount(accountID, db: db)
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM accountMailPreference WHERE accountID = ?", arguments: [accountID]) else {
            return AccountMailPreferences(accountID: accountID)
        }
        let categories: String = row["inboxCategories"]
        let rule: String = row["notificationRule"]
        return AccountMailPreferences(accountID: accountID, nickname: row["nickname"], sortOrder: row["sortOrder"],
            syncEnabled: row["syncEnabled"], profileID: row["profileID"],
            inboxCategories: Set(try decode([String].self, categories).compactMap(InboxCategory.init(rawValue:))),
            notificationRule: MailNotificationRule(rawValue: rule) ?? .off)
    }

    static func allPreferences(db: Database) throws -> [AccountMailPreferences] {
        let accounts = try String.fetchAll(db, sql: """
            SELECT account.id FROM account LEFT JOIN accountMailPreference p ON p.accountID = account.id
            ORDER BY COALESCE(p.sortOrder,0),account.addedAt,account.id
            """)
        return try accounts.map { try preferences(accountID: $0, db: db) }
    }

    static func profiles(db: Database) throws -> [MailProfile] {
        try Row.fetchAll(db, sql: "SELECT * FROM mailProfile ORDER BY sortOrder,name,id").map { row in
            try MailProfile(id: row["id"], name: row["name"], colorIndex: row["colorIndex"], symbol: row["symbol"],
                sortOrder: row["sortOrder"], notificationSchedule: decode(ProfileNotificationSchedule.self, row["schedule"]))
        }
    }
}
