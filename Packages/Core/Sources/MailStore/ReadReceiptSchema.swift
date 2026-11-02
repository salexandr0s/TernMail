import GRDB

enum ReadReceiptSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("read-receipts-v1") { db in
            try db.alter(table: "localDraft") { t in
                t.add(column: "requestsReadReceipt", .boolean).notNull().defaults(to: false)
            }
            // Sent request history survives message-body and metadata eviction.
            try db.create(table: "readReceiptRequest") { t in
                for name in ["accountID", "rfcMessageID", "senderAddress", "subject"] { t.column(name, .text).notNull() }
                t.column("messageID", .text)
                t.column("threadID", .text)
                t.column("sentAt", .datetime).notNull()
                t.primaryKey(["accountID", "rfcMessageID"])
            }
            try db.create(table: "readReceiptRecipient") { t in
                for name in ["accountID", "rfcMessageID", "address"] { t.column(name, .text).notNull() }
                t.primaryKey(["accountID", "rfcMessageID", "address"])
                t.foreignKey(["accountID", "rfcMessageID"], references: "readReceiptRequest", onDelete: .cascade)
            }
            try db.create(index: "readReceiptRecipient_address", on: "readReceiptRecipient", columns: ["accountID", "address"])
            try db.create(table: "readReceiptEvent") { t in
                for name in ["accountID", "receiptMessageID", "rfcMessageID", "recipient", "reporter", "disposition"] {
                    t.column(name, .text).notNull()
                }
                t.column("receivedAt", .datetime).notNull()
                t.column("returnAddresses", .jsonText).notNull()
                t.primaryKey(["accountID", "receiptMessageID"])
            }
            try db.create(index: "readReceiptEvent_match", on: "readReceiptEvent", columns: ["accountID", "rfcMessageID", "recipient"])
            try db.create(table: "readReceiptPending") { t in
                t.column("accountID", .text).notNull()
                t.column("messageID", .text).notNull()
                t.column("lastAttemptAt", .datetime)
                t.primaryKey(["accountID", "messageID"])
            }
        }
    }
}
