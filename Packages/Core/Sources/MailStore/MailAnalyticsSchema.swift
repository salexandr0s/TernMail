import GRDB

enum MailAnalyticsSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("mail-analytics-v1") { db in
            // Metadata remains available after ordinary message and body eviction.
            try db.create(table: "mailAnalyticsMessage") { t in
                for name in ["accountID", "messageID", "threadID", "subject", "sender", "senderAddress", "recipients", "direction"] {
                    t.column(name, .text).notNull()
                }
                t.column("cc", .text)
                t.column("historyID", .integer).notNull()
                t.column("date", .datetime).notNull()
                t.column("labelIDs", .jsonText).notNull()
                t.column("isIncluded", .boolean).notNull()
                t.column("generation", .text)
                t.primaryKey(["accountID", "messageID"])
            }
            try db.create(index: "mailAnalyticsMessage_date", on: "mailAnalyticsMessage", columns: ["accountID", "isIncluded", "date"])
            try db.create(index: "mailAnalyticsMessage_sender", on: "mailAnalyticsMessage", columns: ["accountID", "senderAddress", "date"])
            try db.create(table: "mailAnalyticsContact") { t in
                for name in ["accountID", "messageID", "address"] { t.column(name, .text).notNull() }
                t.column("name", .text)
                t.primaryKey(["accountID", "messageID", "address"])
                t.foreignKey(["accountID", "messageID"], references: "mailAnalyticsMessage", onDelete: .cascade)
            }
            try db.create(index: "mailAnalyticsContact_address", on: "mailAnalyticsContact", columns: ["accountID", "address", "messageID"])
            try db.create(table: "mailAnalyticsState") { t in
                t.primaryKey("accountID", .text)
                t.column("generation", .text).notNull()
                t.column("nextPageToken", .text)
                t.column("historyLoadedAt", .datetime)
                t.column("isComplete", .boolean).notNull()
                t.column("lastError", .text)
            }
            let tx = CacheTransaction(db: db)
            let cursor = try MessageRecord.fetchCursor(db)
            while let message = try cursor.next() {
                let labels = try tx.messageLabelIDs(messageID: message.id, accountID: message.accountID)
                try tx.upsertAnalyticsMessages([.init(record: message, labelIDs: Array(labels))])
            }
        }
    }
}
