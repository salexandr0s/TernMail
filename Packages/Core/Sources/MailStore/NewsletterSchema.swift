import GRDB

enum NewsletterSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("newsletters-v1") { db in
            try db.create(table: "newsletterScanState") { t in
                t.primaryKey("accountID", .text)
                t.column("generation", .text).notNull()
                t.column("displayedGeneration", .text).notNull()
                t.column("nextPageToken", .text)
                t.column("isComplete", .boolean).notNull()
                t.column("lastScannedAt", .datetime)
                t.column("lastError", .text)
            }
            try db.create(table: "newsletterMessage") { t in
                for name in ["accountID", "generation", "messageID", "threadID", "subject", "senderAddress"] {
                    t.column(name, .text).notNull()
                }
                t.column("date", .datetime).notNull()
                for name in ["senderName", "listID", "subscriptionID", "webURL", "mailtoURL", "oneClickURL"] {
                    t.column(name, .text)
                }
                t.primaryKey(["accountID", "generation", "messageID"])
                t.foreignKey(["accountID"], references: "newsletterScanState", onDelete: .cascade)
            }
            try db.create(index: "newsletterMessage_list", on: "newsletterMessage",
                columns: ["accountID", "generation", "subscriptionID", "date", "messageID"])
            try db.create(table: "newsletterOutcome") { t in
                t.column("accountID", .text).notNull()
                t.column("subscriptionID", .text).notNull()
                t.column("status", .text).notNull()
                t.column("statusDate", .datetime).notNull()
                t.column("lastError", .text)
                t.column("requestID", .text)
                t.primaryKey(["accountID", "subscriptionID"])
            }
            try db.create(table: "newsletterScanToken") { t in
                t.column("accountID", .text).notNull()
                t.column("generation", .text).notNull()
                t.column("token", .text).notNull()
                t.primaryKey(["accountID", "generation", "token"])
                t.foreignKey(["accountID"], references: "newsletterScanState", onDelete: .cascade)
            }
        }
    }
}
