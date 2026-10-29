import GRDB

enum Schema {
    static var cacheMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("cache-v1") { db in
            try db.create(table: "label") { t in
                t.column("accountID", .text).notNull()
                t.column("id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("isSystem", .boolean).notNull()
                t.column("textColor", .text)
                t.column("backgroundColor", .text)
                t.column("threadsTotal", .integer)
                t.column("threadsUnread", .integer)
                t.primaryKey(["accountID", "id"])
            }

            try db.create(table: "message") { t in
                t.column("accountID", .text).notNull()
                t.column("id", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("historyID", .integer).notNull()
                t.column("date", .datetime).notNull()
                t.column("snippet", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("recipients", .text).notNull()
                t.column("cc", .text)
                t.column("subject", .text).notNull()
                t.column("sizeEstimate", .integer).notNull()
                t.primaryKey(["accountID", "id"])
            }
            try db.create(index: "message_thread", on: "message", columns: ["accountID", "threadID"])

            // Server state only. Pending local changes are overlaid when threads are rebuilt.
            try db.create(table: "messageLabel") { t in
                t.column("accountID", .text).notNull()
                t.column("messageID", .text).notNull()
                t.column("labelID", .text).notNull()
                t.primaryKey(["accountID", "messageID", "labelID"])
                t.foreignKey(["accountID", "messageID"], references: "message", onDelete: .cascade)
            }

            try db.create(table: "messageBody") { t in
                t.column("accountID", .text).notNull()
                t.column("messageID", .text).notNull()
                t.column("html", .text)
                t.column("plainText", .text)
                t.column("fetchedAt", .datetime).notNull()
                t.primaryKey(["accountID", "messageID"])
                t.foreignKey(["accountID", "messageID"], references: "message", onDelete: .cascade)
            }

            try db.create(table: "thread") { t in
                t.column("accountID", .text).notNull()
                t.column("id", .text).notNull()
                t.column("lastDate", .datetime).notNull()
                t.column("subject", .text).notNull()
                t.column("snippet", .text).notNull()
                t.column("participants", .text).notNull()
                t.column("messageCount", .integer).notNull()
                t.column("isUnread", .boolean).notNull()
                t.column("isStarred", .boolean).notNull()
                t.primaryKey(["accountID", "id"])
            }

            try db.create(table: "threadLabel") { t in
                t.column("accountID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("labelID", .text).notNull()
                t.column("lastDate", .datetime).notNull()
                t.primaryKey(["accountID", "threadID", "labelID"])
                t.foreignKey(["accountID", "threadID"], references: "thread", onDelete: .cascade)
            }
            try db.create(
                index: "threadLabel_list",
                on: "threadLabel",
                columns: ["accountID", "labelID", "lastDate", "threadID"]
            )

            try db.create(table: "pendingAction") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("threadIDs", .jsonText).notNull()
                t.column("messageIDs", .jsonText).notNull()
                t.column("addLabelIDs", .jsonText).notNull()
                t.column("removeLabelIDs", .jsonText).notNull()
                t.column("diff", .jsonText).notNull()
                t.column("state", .text).notNull()
                t.column("attempts", .integer).notNull()
                t.column("lastError", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("notBefore", .datetime).notNull()
                t.column("sentAt", .datetime)
            }

            try db.create(table: "syncState") { t in
                t.primaryKey("accountID", .text)
                t.column("historyID", .integer).notNull()
                t.column("lastFullSyncAt", .datetime).notNull()
            }
        }
        return migrator
    }

    static var configMigrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("config-v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("email", .text).notNull()
                t.column("displayName", .text)
                t.column("grantedScopes", .jsonText).notNull()
                t.column("addedAt", .datetime).notNull()
            }
        }
        return migrator
    }
}
