import GRDB

enum AttachmentClassificationSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("attachment-classification-v1") { db in
            try db.alter(table: "attachmentLibrary") { t in
                t.add(column: "categorySource", .text).notNull().defaults(to: "metadata")
                t.add(column: "classificationVersion", .integer).notNull().defaults(to: 0)
                t.add(column: "contentClassificationVersion", .integer).notNull().defaults(to: 0)
                t.add(column: "classificationRetryAfter", .datetime)
            }
            // Before automatic classification, every assigned category was a
            // user choice. Revision rows also preserve explicit Uncategorized.
            try db.execute(sql: """
                UPDATE attachmentLibrary SET categorySource = 'manual'
                WHERE category != 'uncategorized' OR EXISTS (
                    SELECT 1 FROM attachmentCategoryRevision r
                    WHERE r.accountID = attachmentLibrary.accountID
                      AND r.messageID = attachmentLibrary.messageID
                      AND r.partID = attachmentLibrary.partID)
                """)

            // Already-complete libraries need no provider rescan. Keyset
            // batches bound memory even for accounts with years of files.
            var lastRowID: Int64 = 0
            while true {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT rowid AS classificationRowID, filename, mimeType, subject
                    FROM attachmentLibrary WHERE categorySource = 'metadata' AND rowid > ?
                    ORDER BY rowid LIMIT 250
                    """, arguments: [lastRowID])
                guard !rows.isEmpty else { break }
                for row in rows {
                    let rowID: Int64 = row["classificationRowID"]
                    let inferred = AttachmentClassification.metadataClassification(filename: row["filename"],
                        mimeType: row["mimeType"], subject: row["subject"])
                    try db.execute(sql: "UPDATE attachmentLibrary SET category = ?, categorySource = ?, classificationVersion = ? WHERE rowid = ?",
                        arguments: [inferred.category.rawValue, inferred.source.rawValue, 1, rowID])
                    lastRowID = rowID
                }
            }
            try db.create(index: "attachmentLibrary_classification", on: "attachmentLibrary",
                columns: ["accountID", "category", "contentClassificationVersion", "date"])
        }
        migrator.registerMigration("attachment-classification-v2") { db in
            // Updated rules can resolve metadata missed by the previous version.
            // Keep manual choices and successful content results. Unresolved
            // content attempts retain version 1 so the worker can retry once.
            var lastRowID: Int64 = 0
            while true {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT rowid AS classificationRowID, filename, mimeType, subject
                    FROM attachmentLibrary WHERE rowid > ? AND classificationVersion < 2
                      AND (categorySource IN ('metadata','subject')
                           OR (categorySource = 'content' AND category = 'uncategorized'))
                    ORDER BY rowid LIMIT 250
                    """, arguments: [lastRowID])
                guard !rows.isEmpty else { break }
                for row in rows {
                    let rowID: Int64 = row["classificationRowID"]
                    let inferred = AttachmentClassification.metadataClassification(filename: row["filename"],
                        mimeType: row["mimeType"], subject: row["subject"])
                    try db.execute(sql: """
                        UPDATE attachmentLibrary
                        SET category = ?, categorySource = ?, classificationVersion = 2, classificationRetryAfter = NULL
                        WHERE rowid = ?
                        """, arguments: [inferred.category.rawValue, inferred.source.rawValue, rowID])
                    lastRowID = rowID
                }
            }
        }
    }
}
