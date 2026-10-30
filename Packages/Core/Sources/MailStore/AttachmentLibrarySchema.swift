import GRDB

enum AttachmentLibrarySchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("attachment-library-v1") { db in
            // This index outlives ordinary cache eviction, so it has no message foreign key.
            try db.create(table: "attachmentLibrary") { t in
                for name in ["accountID", "messageID", "partID", "threadID", "filename", "mimeType", "sender", "subject",
                             "fileExtension", "searchText", "senderSearch", "category"] { t.column(name, .text).notNull() }
                t.column("attachmentID", .text)
                t.column("size", .integer).notNull()
                t.column("date", .datetime).notNull()
                t.column("labelIDs", .jsonText).notNull()
                t.column("historyID", .integer).notNull()
                t.column("generation", .text)
                t.primaryKey(["accountID", "messageID", "partID"])
            }
            for column in ["date", "size", "filename", "sender", "fileExtension", "category"] {
                try db.create(index: "attachmentLibrary_\(column)", on: "attachmentLibrary", columns: ["accountID", column])
            }
            try db.create(table: "attachmentLibraryLabel") { t in
                for name in ["accountID", "messageID", "labelID"] { t.column(name, .text).notNull() }
                t.primaryKey(["accountID", "messageID", "labelID"])
            }
            try db.create(index: "attachmentLibraryLabel_filter", on: "attachmentLibraryLabel", columns: ["accountID", "labelID", "messageID"])
            try db.create(table: "attachmentIndexState") { t in
                t.primaryKey("accountID", .text)
                for name in ["nextPageToken", "historyPageToken", "lastError", "generation"] { t.column(name, .text) }
                for name in ["historyID", "historyTargetID"] { t.column(name, .integer) }
                t.column("indexedMessageCount", .integer).notNull()
                t.column("isComplete", .boolean).notNull()
                t.column("failureCount", .integer).notNull()
                for name in ["updatedAt", "lastReconciledAt", "retryAfter"] { t.column(name, .datetime) }
            }
        }
        migrator.registerMigration("attachment-library-v2") { db in
            try db.alter(table: "attachmentIndexState") { t in
                t.add(column: "pendingMessageIDs", .jsonText).notNull().defaults(to: "[]")
            }
        }
    }
}
