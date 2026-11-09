import GRDB

enum CommitmentSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("commitments-v1") { db in
            try db.create(table: "commitment") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("sourceMessageID", .text).notNull()
                t.column("sourceMessageDate", .datetime).notNull()
                t.column("sourceSubject", .text).notNull()
                t.column("title", .text).notNull()
                t.column("ownerName", .text)
                t.column("ownerEmail", .text)
                t.column("direction", .text).notNull()
                t.column("status", .text).notNull()
                t.column("dueAt", .datetime)
                t.column("acceptanceKey", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("revision", .integer).notNull()
                t.primaryKey(["accountID", "id"])
                t.uniqueKey(["accountID", "acceptanceKey"])
            }
            try db.create(index: "commitmentAccountStatusDue", on: "commitment", columns: ["accountID", "status", "dueAt"])
            try db.create(table: "commitmentReminder") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("commitmentID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("remindAt", .datetime).notNull()
                t.column("baselineMessageID", .text).notNull()
                t.column("baselineDate", .datetime).notNull()
                t.column("baselineHistoryID", .integer)
                t.column("receivedReplyMessageID", .text)
                t.column("receivedReplyAt", .datetime)
                t.column("deliveredAt", .datetime)
                t.column("revision", .integer).notNull()
                t.primaryKey(["accountID", "commitmentID", "kind"])
                t.foreignKey(["accountID", "commitmentID"], references: "commitment", columns: ["accountID", "id"], onDelete: .cascade)
            }
            try db.create(index: "commitmentReminderDue", on: "commitmentReminder", columns: ["accountID", "remindAt"])
        }
        migrator.registerMigration("commitment-notification-id-v1") { db in
            try db.alter(table: "commitmentReminder") { t in
                t.add(column: "notificationID", .text)
            }
        }
    }
}
