import GRDB

enum Milestone5CacheSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("reading-resources-v1") { db in
            try db.create(table: "mimeResource") { t in
                for name in ["accountID", "messageID", "contentID", "partID", "mimeType"] { t.column(name, .text).notNull() }
                t.column("data", .blob).notNull()
                t.primaryKey(["accountID", "messageID", "contentID"])
                t.foreignKey(["accountID", "messageID"], references: "message", onDelete: .cascade)
            }
            try db.create(table: "threadOpened") { t in
                t.column("accountID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("lastOpenedAt", .datetime).notNull()
                t.primaryKey(["accountID", "threadID"])
                t.foreignKey(["accountID", "threadID"], references: "thread", onDelete: .cascade)
            }
        }
        migrator.registerMigration("mail-list-metadata-v1") { db in
            try db.alter(table: "label") { t in
                t.add(column: "labelListVisibility", .text)
                t.add(column: "messagesTotal", .integer)
                t.add(column: "messagesUnread", .integer)
            }
        }
        migrator.registerMigration("compose-extras-v1") { db in
            try db.alter(table: "localDraft") { t in
                t.add(column: "composeFont", .text).notNull().defaults(to: "sansSerif")
                t.add(column: "signatureAboveQuote", .boolean).notNull().defaults(to: true)
                t.add(column: "signatureSeparator", .boolean).notNull().defaults(to: false)
                t.add(column: "archiveAfterSend", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "outgoingAttachment") { t in t.add(column: "contentID", .text) }
        }
        migrator.registerMigration("attachment-category-revisions-v1") { db in
            try db.create(table: "attachmentCategoryRevision") { t in
                for name in ["accountID", "messageID", "partID"] { t.column(name, .text).notNull() }
                t.column("revision", .integer).notNull()
                t.primaryKey(["accountID", "messageID", "partID"])
                t.foreignKey(["accountID", "messageID", "partID"], references: "attachmentLibrary", onDelete: .cascade)
            }
        }
        migrator.registerMigration("contact-enrichment-v1") { db in
            try db.create(table: "contactPhoto") { t in
                for name in ["accountID", "source", "resourceName", "url", "version"] { t.column(name, .text).notNull() }
                t.column("data", .blob)
                t.column("fetchedAt", .datetime)
                t.primaryKey(["accountID", "source", "resourceName"])
                t.foreignKey(["accountID", "source", "resourceName"], references: "contact", onDelete: .cascade)
            }
            try db.create(table: "contactGroup") { t in
                for name in ["accountID", "source", "resourceName", "name"] { t.column(name, .text).notNull() }
                t.column("memberCount", .integer).notNull()
                t.column("isComplete", .boolean).notNull()
                t.column("fetchedAt", .datetime).notNull()
                t.primaryKey(["accountID", "resourceName"])
                t.foreignKey(["accountID", "source"], references: "contactSync", onDelete: .cascade)
            }
        }
        migrator.registerMigration("contact-enrichment-generation-v1") { db in
            try db.create(table: "contactEnrichmentGeneration") { t in
                t.primaryKey("accountID", .text)
                t.column("source", .text).notNull()
                t.column("generation", .text).notNull()
                t.foreignKey(["accountID", "source"], references: "contactSync", onDelete: .cascade)
            }
            try db.execute(sql: """
                INSERT INTO contactEnrichmentGeneration (accountID,source,generation)
                SELECT accountID,source,lower(hex(randomblob(16))) FROM contactSync WHERE source = 'connection'
                """)
        }
    }
}
