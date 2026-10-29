import GRDB
import MessageContent

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

        migrator.registerMigration("compose-v1") { db in
            // Threading headers for replies. Rows cached earlier stay nil until
            // a reply fetches them.
            try db.alter(table: "message") { t in
                t.add(column: "rfcMessageID", .text)
                t.add(column: "inReplyTo", .text)
                t.add(column: "referencesHeader", .text)
                t.add(column: "replyTo", .text)
            }
            try db.alter(table: "pendingAction") { t in
                t.add(column: "localDraftID", .text)
            }

            // Gmail's drafts, from drafts.list and from our own saves.
            try db.create(table: "draft") { t in
                t.column("accountID", .text).notNull()
                t.column("id", .text).notNull()
                t.column("messageID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.primaryKey(["accountID", "id"])
            }
            try db.create(index: "draft_message", on: "draft", columns: ["accountID", "messageID"])

            // Compose state. Not disposable: it holds what hasn't reached Gmail.
            try db.create(table: "localDraft") { t in
                t.primaryKey("id", .text)
                t.column("accountID", .text).notNull()
                t.column("gmailDraftID", .text)
                t.column("savedMessageID", .text)
                t.column("threadID", .text)
                t.column("kind", .text).notNull()
                t.column("sourceMessageID", .text)
                t.column("toAddresses", .jsonText).notNull()
                t.column("ccAddresses", .jsonText).notNull()
                t.column("bccAddresses", .jsonText).notNull()
                t.column("subject", .text).notNull()
                t.column("body", .jsonText).notNull()
                t.column("quotedHTML", .text)
                t.column("quotedPlainText", .text)
                t.column("rfcMessageID", .text).notNull()
                t.column("inReplyTo", .text)
                t.column("referencesHeader", .jsonText).notNull()
                t.column("revision", .integer).notNull()
                t.column("savedRevision", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("sendError", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // SQLite lets several rows share NULL, so only saved drafts are unique.
            try db.create(index: "localDraft_gmailDraft", on: "localDraft", columns: ["accountID", "gmailDraftID"], unique: true)

            try db.create(table: "outgoingAttachment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("localDraftID", .text).notNull().indexed()
                    .references("localDraft", onDelete: .cascade)
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("path", .text).notNull()
            }

            // Received attachments, keyed by part ID: Gmail may change the
            // attachment ID each time it returns a message.
            try db.create(table: "attachment") { t in
                t.column("accountID", .text).notNull()
                t.column("messageID", .text).notNull()
                t.column("partID", .text).notNull()
                t.column("attachmentID", .text)
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("isInline", .boolean).notNull()
                t.primaryKey(["accountID", "messageID", "partID"])
                t.foreignKey(["accountID", "messageID"], references: "message", onDelete: .cascade)
            }
        }

        migrator.registerMigration("search-v1") { db in
            // The text the search index reads. Metadata arrives through the
            // triggers below; body text is written in Swift by `saveBodies`.
            try db.create(table: "messageText") { t in
                t.primaryKey("id", .integer)
                t.column("accountID", .text).notNull()
                t.column("messageID", .text).notNull()
                t.column("subject", .text)
                t.column("sender", .text)
                t.column("recipients", .text)
                t.column("cc", .text)
                t.column("snippet", .text)
                t.column("body", .text)
                t.uniqueKey(["accountID", "messageID"])
                t.foreignKey(["accountID", "messageID"], references: "message", onDelete: .cascade)
            }
            try db.create(virtualTable: "messageSearch", using: FTS5()) { t in
                t.synchronize(withTable: "messageText")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3]
                for column in ["subject", "sender", "recipients", "cc", "snippet", "body"] {
                    t.column(column)
                }
            }
            // GRDB updates write every column, so the WHEN clause keeps a label
            // change or a history ID bump from re-indexing the message.
            try db.execute(sql: """
                CREATE TRIGGER message_text_insert AFTER INSERT ON message BEGIN
                    INSERT INTO messageText (accountID, messageID, subject, sender, recipients, cc, snippet)
                    VALUES (NEW.accountID, NEW.id, NEW.subject, NEW.sender, NEW.recipients, NEW.cc, NEW.snippet)
                    ON CONFLICT (accountID, messageID) DO UPDATE SET
                        subject = excluded.subject, sender = excluded.sender, recipients = excluded.recipients,
                        cc = excluded.cc, snippet = excluded.snippet;
                END;
                CREATE TRIGGER message_text_update AFTER UPDATE ON message
                WHEN NEW.subject IS NOT OLD.subject OR NEW.sender IS NOT OLD.sender
                    OR NEW.recipients IS NOT OLD.recipients OR NEW.cc IS NOT OLD.cc OR NEW.snippet IS NOT OLD.snippet
                BEGIN
                    UPDATE messageText
                    SET subject = NEW.subject, sender = NEW.sender, recipients = NEW.recipients,
                        cc = NEW.cc, snippet = NEW.snippet
                    WHERE accountID = NEW.accountID AND messageID = NEW.id;
                END;
                INSERT INTO messageText (accountID, messageID, subject, sender, recipients, cc, snippet)
                SELECT accountID, id, subject, sender, recipients, cc, snippet FROM message;
                """)
            // Raw rows, so later changes to the record types can't break this step.
            let bodies = try Row.fetchCursor(db, sql: "SELECT accountID, messageID, html, plainText FROM messageBody")
            while let row = try bodies.next() {
                let text = SearchText.body(html: row["html"], plainText: row["plainText"])
                try db.execute(
                    sql: "UPDATE messageText SET body = ? WHERE accountID = ? AND messageID = ?",
                    arguments: [text, row["accountID"], row["messageID"]]
                )
            }

            // Conversations kept in the cache for a reason of Tern's own: a
            // search result, or a snoozed conversation.
            try db.create(table: "cacheHold") { t in
                t.column("accountID", .text).notNull()
                t.column("threadID", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("expiresAt", .datetime)
                t.column("wakeAt", .datetime)
                t.primaryKey(["accountID", "threadID", "reason"])
            }
        }

        migrator.registerMigration("labels-v1") { db in
            // The label a create, update or delete row changes, and the change.
            try db.alter(table: "pendingAction") { t in
                t.add(column: "labelID", .text)
                t.add(column: "labelChange", .jsonText)
            }
            // Gmail's ID for a label created under a temporary one, so rows and
            // undos made with the temporary ID still reach the label.
            try db.create(table: "labelAlias") { t in
                t.column("accountID", .text).notNull()
                t.column("temporaryID", .text).notNull()
                t.column("realID", .text).notNull()
                t.primaryKey(["accountID", "temporaryID"])
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
