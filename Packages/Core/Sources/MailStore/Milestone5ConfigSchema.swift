import GRDB

enum Milestone5ConfigSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("mail-preferences-v1") { db in
            try db.create(table: "mailProfile") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("colorIndex", .integer).notNull()
                t.column("symbol", .text).notNull()
                t.column("sortOrder", .integer).notNull()
                t.column("schedule", .jsonText).notNull()
            }
            try db.create(table: "accountMailPreference") { t in
                t.primaryKey("accountID", .text).references("account", onDelete: .cascade)
                t.column("nickname", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("syncEnabled", .boolean).notNull().defaults(to: true)
                t.column("profileID", .text).references("mailProfile", onDelete: .setNull)
                t.column("inboxCategories", .jsonText).notNull().defaults(to: "[]")
                t.column("notificationRule", .text).notNull().defaults(to: "off")
            }
            for table in ["imageSenderAllow", "suggestionBlock"] {
                try db.create(table: table) { t in
                    t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                    t.column("address", .text).notNull()
                    t.primaryKey(["accountID", "address"])
                }
            }
            try db.create(table: "mailAlertWatermark") { t in
                t.primaryKey("accountID", .text).references("account", onDelete: .cascade)
                t.column("historyID", .integer).notNull()
                t.column("baselineAt", .datetime).notNull()
            }
            try db.create(table: "mailSavedSearch") { t in
                t.primaryKey("id", .text)
                for column in ["name", "query"] { t.column(column, .text).notNull() }
                t.column("allAccounts", .boolean).notNull()
                t.column("sortOrder", .integer).notNull()
            }
            try db.create(table: "mailFavorite") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("labelID", .text)
                t.column("accountID", .text).references("account", onDelete: .cascade)
                t.column("savedSearchID", .text).references("mailSavedSearch", onDelete: .cascade)
                t.column("allAccounts", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull()
            }
            for (table, parent, key) in [("mailSavedSearchAccount", "mailSavedSearch", "searchID"),
                                         ("mailFavoriteAccount", "mailFavorite", "favoriteID")] {
                try db.create(table: table) { t in
                    t.column(key, .text).notNull().references(parent, onDelete: .cascade)
                    t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                    t.primaryKey([key, "accountID"])
                }
            }
            for table in ["composeTemplate", "localSignature"] {
                try db.create(table: table) { t in
                    t.primaryKey("id", .text)
                    t.column("name", .text).notNull()
                    t.column("document", .jsonText).notNull()
                    t.column("sortOrder", .integer).notNull()
                }
            }
            try db.create(table: "signatureAssignment") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("address", .text).notNull()
                t.column("newMessages", .jsonText).notNull()
                t.column("replies", .jsonText).notNull()
                t.column("placeAboveQuote", .boolean).notNull()
                t.column("includeSeparator", .boolean).notNull()
                t.primaryKey(["accountID", "address"])
            }
            // Keep migration data independent of later record/store changes.
            for (index, labelID) in ["INBOX", "STARRED", "TERN_SNOOZED", "SENT", "DRAFT", "TERN_ALL_MAIL", "SPAM", "TRASH"].enumerated() {
                try db.execute(sql: "INSERT INTO mailFavorite (id,kind,labelID,allAccounts,sortOrder) VALUES (?,'mailbox',?,1,?)",
                    arguments: ["default:" + labelID, labelID, index])
            }
        }
        migrator.registerMigration("attachment-category-overrides-v1") { db in
            try db.create(table: "attachmentCategoryOverride") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("messageID", .text).notNull()
                t.column("partID", .text).notNull()
                t.column("category", .text).notNull()
                t.column("revision", .integer).notNull()
                t.primaryKey(["accountID", "messageID", "partID"])
            }
        }
        migrator.registerMigration("mail-alert-outbox-v1") { db in
            try db.create(table: "mailPendingAlert") { t in
                t.column("accountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("messageID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("addedHistoryID", .integer).notNull()
                t.primaryKey(["accountID", "messageID"])
            }
        }
        migrator.registerMigration("unread-favorite-v1") { db in
            let favorites = try Row.fetchAll(db, sql: "SELECT id,kind,labelID,allAccounts FROM mailFavorite ORDER BY sortOrder,id")
            let hasUnread = favorites.contains {
                ($0["kind"] as String) == "mailbox" && ($0["labelID"] as String?) == "UNREAD" && ($0["allAccounts"] as Bool)
            }
            guard !hasUnread, let inboxIndex = favorites.firstIndex(where: {
                ($0["kind"] as String) == "mailbox" && ($0["labelID"] as String?) == "INBOX" && ($0["allAccounts"] as Bool)
            }) else { return }
            var ids = favorites.map { $0["id"] as String }
            guard !ids.contains("default:UNREAD") else { return }
            ids.insert("default:UNREAD", at: inboxIndex + 1)
            try db.execute(sql: "INSERT INTO mailFavorite (id,kind,labelID,allAccounts,sortOrder) VALUES ('default:UNREAD','mailbox','UNREAD',1,?)",
                arguments: [inboxIndex + 1])
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE mailFavorite SET sortOrder = ? WHERE id = ?", arguments: [index, id])
            }
        }
    }
}
