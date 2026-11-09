import GRDB

enum TodaySchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("commitment-deferral-v1") { db in
            try db.alter(table: "commitment") { t in t.add(column: "deferredUntil", .datetime) }
        }
        migrator.registerMigration("today-visits-v1") { db in
            try db.create(table: "todayVisit") { t in
                t.column("scopeKey", .text).notNull()
                t.column("profileID", .text).references("mailProfile", onDelete: .cascade)
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("firstVisitedAt", .datetime).notNull()
                t.column("lastVisitedAt", .datetime).notNull()
                t.primaryKey(["scopeKey", "accountID"])
            }
            try db.create(table: "todaySeenCommitment") { t in
                t.column("scopeKey", .text).notNull()
                t.column("accountID", .text).notNull()
                t.column("commitmentID", .text).notNull()
                t.column("snapshot", .jsonText).notNull()
                t.column("recordRevision", .integer).notNull()
                t.column("seenAt", .datetime).notNull()
                t.primaryKey(["scopeKey", "accountID", "commitmentID"])
                t.foreignKey(["scopeKey", "accountID"], references: "todayVisit", columns: ["scopeKey", "accountID"], onDelete: .cascade)
                t.foreignKey(["accountID", "commitmentID"], references: "commitment", columns: ["accountID", "id"], onDelete: .cascade)
            }
        }
    }
}
