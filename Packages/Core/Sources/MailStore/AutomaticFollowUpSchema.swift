import GRDB

enum AutomaticFollowUpSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("automatic-followups-v1") { db in
            try db.create(table: "automaticFollowUpPolicy") { t in
                t.primaryKey("accountID", .text).references("account", onDelete: .cascade)
                t.column("enabled", .boolean).notNull()
                t.column("delayDays", .integer).notNull()
                t.column("enabledSince", .datetime).notNull()
            }
            try db.create(table: "automaticFollowUp") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("threadID", .text).notNull()
                t.column("commitmentID", .text).notNull()
                t.column("managed", .boolean).notNull()
                t.column("latestOutgoingMessageID", .text).notNull()
                t.column("latestOutgoingDate", .datetime).notNull()
                t.column("delayDays", .integer).notNull()
                t.column("eligibleForAlerts", .boolean).notNull()
                t.column("scheduleEnabled", .boolean).notNull()
                t.column("revision", .integer).notNull()
                t.primaryKey(["accountID", "threadID"])
                t.uniqueKey(["accountID", "commitmentID"])
                t.foreignKey(["accountID", "commitmentID"], references: "commitment", columns: ["accountID", "id"], onDelete: .cascade)
            }
            try db.create(table: "automaticFollowUpDraft") { t in
                t.column("accountID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("commitmentID", .text).notNull()
                t.column("outgoingMessageID", .text).notNull()
                t.column("claimID", .text).notNull().unique()
                t.column("draftID", .text).notNull().unique()
                t.column("state", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("automationRevision", .integer).notNull()
                t.primaryKey(["accountID", "threadID", "outgoingMessageID"])
                t.foreignKey(["accountID", "threadID"], references: "automaticFollowUp", columns: ["accountID", "threadID"], onDelete: .cascade)
                t.foreignKey(["accountID", "commitmentID"], references: "commitment", columns: ["accountID", "id"], onDelete: .cascade)
            }
        }
        migrator.registerMigration("automatic-followups-adoption-v1") { db in
            try db.alter(table: "automaticFollowUpPolicy") { t in
                t.add(column: "active", .boolean).notNull().defaults(to: true)
                t.add(column: "adoptedAt", .datetime)
            }
        }
    }
}
