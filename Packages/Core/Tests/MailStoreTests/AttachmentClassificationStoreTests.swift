import Foundation
import GRDB
import Testing
@testable import MailStore

@Suite struct AttachmentClassificationStoreTests {
    @Test func upgradeClassifiesExistingLibraryWithoutOverwritingManualChoices() async throws {
        let writer = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(writer, upTo: "contact-enrichment-generation-v1")
        try await writer.write { db in
            for index in 0..<253 {
                let category = index == 251 ? "receipt" : "uncategorized"
                try db.execute(sql: """
                    INSERT INTO attachmentLibrary
                    (accountID,messageID,partID,threadID,filename,mimeType,sender,subject,fileExtension,
                     searchText,senderSearch,category,size,date,labelIDs,historyID)
                    VALUES ('a',?,'1','t','invoice.pdf','application/pdf','','Document','pdf','','',?,100,?, '[]',1)
                    """, arguments: ["m\(index)", category, Date(timeIntervalSince1970: 1_000)])
            }
            try db.execute(sql: "UPDATE attachmentLibrary SET filename = 'document.pdf', subject = 'Your receipt' WHERE messageID = 'm250'")
            try db.execute(sql: """
                INSERT INTO attachmentCategoryRevision (accountID,messageID,partID,revision) VALUES ('a','m252','1',1)
                """)
            try db.execute(sql: """
                INSERT INTO attachmentIndexState (accountID,historyID,indexedMessageCount,isComplete,failureCount,pendingMessageIDs)
                VALUES ('a',100,253,1,0,'[]')
                """)
        }
        let cache = try MailCache(writer: writer)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], category: .invoice)).totalCount == 250)
        let overrides = try await cache.attachmentCategorySnapshot()
        #expect(overrides.count == 2)
        #expect(Set(overrides.map(\.category)) == [.receipt, .uncategorized])
        #expect(try await cache.read { try $0.attachmentIndexState(accountID: "a")?.isComplete } == true)
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a").map(\.messageID) == ["m250"])
        #expect(try await item(cache, "m250").categorySource == .subject)
    }

    @Test func inferenceAndExplicitUncategorizedRemainDistinctAcrossCacheReset() async throws {
        let cache = try MailCache.inMemory()
        let store = try AccountStore.inMemory()
        try await store.save(.init(id: "a", email: "a@example.test", displayName: nil,
            grantedScopes: [], addedAt: .distantPast))
        try await seed(cache, id: "auto", filename: "invoice.pdf")
        try await seed(cache, id: "manual", filename: "invoice.pdf")
        try await cache.write { try $0.setAttachmentCategory(.uncategorized, accountID: "a", messageID: "manual", partID: "1") }
        let snapshot = try await cache.attachmentCategorySnapshot()
        #expect(snapshot.map(\.messageID) == ["manual"])
        #expect(snapshot.first?.category == .uncategorized)
        try await store.importAttachmentCategoryOverrides(snapshot)
        try await cache.resetDisposableCache()
        try await seed(cache, id: "auto", filename: "invoice.pdf")
        try await seed(cache, id: "manual", filename: "invoice.pdf")
        try await cache.applyAttachmentCategoryOverrides(store.attachmentCategoryOverrides(accountID: "a"))
        #expect(try await item(cache, "auto").category == .invoice)
        #expect(try await item(cache, "auto").categorySource == .metadata)
        #expect(try await item(cache, "manual").category == .uncategorized)
        #expect(try await item(cache, "manual").categorySource == .manual)
    }

    @Test func versionTwoRechecksOldPredictionsAndRetriesOnlyUnresolvedContent() async throws {
        let writer = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(writer, upTo: "attachment-classification-v1")
        let fixtures = ["compound", "manual", "metadata", "resolved", "subject", "unresolved"].map { id in
            let filename = ["compound", "manual"].contains(id) ? "Rechnungskopie_2026.pdf"
                : id == "metadata" ? "receipt.pdf" : "document.pdf"
            let attachment = AttachmentRecord(accountID: "a", messageID: id, partID: "1", attachmentID: "download",
                filename: filename, mimeType: "application/pdf", size: 100, isInline: false)
            var item = AttachmentLibraryItem(attachment: attachment, threadID: "t", sender: "sender@example.test",
                subject: id == "subject" ? "Ihre Rechnungskopie" : "Document", date: Date(timeIntervalSince1970: 1_000))
            item.category = id == "resolved" ? .ticket : id == "metadata" ? .invoice : id == "subject" ? .receipt : .uncategorized
            item.categorySource = id == "manual" ? .manual : ["resolved", "unresolved"].contains(id) ? .content
                : id == "subject" ? .subject : .metadata
            item.classificationVersion = 1
            item.contentClassificationVersion = ["resolved", "unresolved"].contains(id) ? 1 : 0
            item.classificationRetryAfter = .distantFuture
            return item
        }
        try await writer.write { db in for item in fixtures { try item.insert(db) } }

        let cache = try MailCache(writer: writer)
        #expect(try await item(cache, "compound").category == .invoice)
        #expect(try await item(cache, "compound").classificationVersion == 2)
        #expect(try await item(cache, "metadata").category == .receipt)
        #expect(try await item(cache, "subject").category == .invoice)
        #expect(try await item(cache, "subject").categorySource == .subject)
        #expect(try await item(cache, "manual").category == .uncategorized)
        #expect(try await item(cache, "manual").categorySource == .manual)
        #expect(try await item(cache, "resolved").category == .ticket)
        #expect(try await item(cache, "resolved").classificationVersion == 1)
        #expect(try await item(cache, "resolved").contentClassificationVersion == 1)
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a").map(\.messageID) == ["subject", "unresolved"])

        let unresolved = try await item(cache, "unresolved")
        try await cache.applyAttachmentClassification(.uncategorized, for: unresolved)
        let subject = try await item(cache, "subject")
        try await cache.applyAttachmentClassification(.invoice, for: subject)
        let reopened = try MailCache(writer: writer)
        #expect(try await reopened.pendingAttachmentClassifications(accountID: "a").isEmpty)
        #expect(try await item(reopened, "unresolved").contentClassificationVersion == 2)
    }

    @Test func metadataRefreshRechecksOldRulesWithoutRestampingSuccessfulContent() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, id: "metadata", filename: "Rechnungskopie_2026.pdf")
        try await seed(cache, id: "content")
        try await cache.write { tx in
            try tx.db.execute(sql: """
                UPDATE attachmentLibrary SET category = 'uncategorized', categorySource = 'metadata', classificationVersion = 1
                WHERE messageID = 'metadata'
                """)
            try tx.db.execute(sql: """
                UPDATE attachmentLibrary SET category = 'ticket', categorySource = 'content', classificationVersion = 1,
                    contentClassificationVersion = 1 WHERE messageID = 'content'
                """)
        }
        try await seed(cache, id: "metadata", filename: "Rechnungskopie_2026.pdf", historyID: 2)
        try await seed(cache, id: "content", historyID: 2)
        #expect(try await item(cache, "metadata").category == .invoice)
        #expect(try await item(cache, "metadata").classificationVersion == 2)
        #expect(try await item(cache, "content").category == .ticket)
        #expect(try await item(cache, "content").classificationVersion == 1)
        #expect(try await item(cache, "content").contentClassificationVersion == 1)
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a").isEmpty)
    }

    @Test func contentQueueIsScopedBoundedAndDoesNotRepeatCompletedOrDeferredFiles() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, id: "one")
        try await seed(cache, id: "two", filename: "image.png", mimeType: "image/png")
        try await seed(cache, id: "oversized", size: AttachmentClassification.maximumContentBytes + 1)
        try await seed(cache, id: "unsupported", filename: "archive.zip", mimeType: "application/zip")
        try await seed(cache, id: "recognized", filename: "receipt.pdf")
        try await seed(cache, id: "different-account", accountID: "b")
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a", limit: 1).count == 1)
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a", limit: 0).isEmpty)
        let pending = try await cache.pendingAttachmentClassifications(accountID: "a")
        #expect(pending.map(\.messageID) == ["one", "two"])
        let first = try #require(pending.first)
        let now = Date(timeIntervalSince1970: 2_000)
        try await cache.deferAttachmentClassification(for: first, until: now.addingTimeInterval(60))
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a", now: now).map(\.messageID) == ["two"])
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a", now: now.addingTimeInterval(60)).count == 2)
        let second = try #require(pending.last)
        try await cache.applyAttachmentClassification(.uncategorized, for: second)
        try await seed(cache, id: "two", filename: "image.png", mimeType: "image/png")
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a", now: now).isEmpty)
        #expect(try await item(cache, "two").contentClassificationVersion == AttachmentClassification.version)
        try await seed(cache, id: "csv", filename: "download", mimeType: "text/csv; charset=utf-8")
        try await seed(cache, id: "heif", filename: "scan.heif", mimeType: "application/octet-stream")
        #expect(try await cache.pendingAttachmentClassifications(accountID: "a", now: now).map(\.messageID) == ["csv", "heif"])
    }

    @Test func contentResultsSurviveLabelRefreshButCannotReplaceManualOrChangedFiles() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, id: "content")
        let original = try await item(cache, "content")
        try await cache.write { tx in
            try tx.applyLibraryLabelChange(messageID: "content", added: ["read"], removed: [], historyID: 2, accountID: "a")
        }
        try await cache.applyAttachmentClassification(.ticket, for: original)
        try await seed(cache, id: "content", historyID: 3, attachmentID: "new-download-hint")
        let classified = try await item(cache, "content")
        #expect(classified.category == .ticket)
        #expect(classified.categorySource == .content)
        #expect(classified.contentClassificationVersion == AttachmentClassification.version)
        #expect(try await cache.attachmentCategorySnapshot().isEmpty)

        // A late response for an earlier file or manual choice is discarded.
        try await seed(cache, id: "content", filename: "receipt.pdf", historyID: 4)
        try await cache.applyAttachmentClassification(.contract, for: classified)
        #expect(try await item(cache, "content").category == .receipt)
        let beforeEdit = try await item(cache, "content")
        try await cache.write { try $0.setAttachmentCategory(.uncategorized, accountID: "a", messageID: "content", partID: "1") }
        try await cache.applyAttachmentClassification(.invoice, for: beforeEdit)
        try await seed(cache, id: "content", filename: "receipt.pdf", historyID: 5)
        #expect(try await item(cache, "content").category == .uncategorized)
        #expect(try await item(cache, "content").categorySource == .manual)

        try await seed(cache, id: "ambiguous", subject: "Your receipt")
        let provisional = try await item(cache, "ambiguous")
        #expect(provisional.categorySource == .subject)
        try await cache.applyAttachmentClassification(.uncategorized, for: provisional)
        #expect(try await item(cache, "ambiguous").category == .uncategorized)
        #expect(try await item(cache, "ambiguous").categorySource == .content)
    }

    private func seed(_ cache: MailCache, id: String, accountID: String = "a", filename: String = "document.pdf",
                      mimeType: String = "application/pdf", size: Int = 100, historyID: Int64 = 1,
                      attachmentID: String = "download", subject: String = "Document") async throws {
        let message = MessageRecord(accountID: accountID, id: id, threadID: "t-\(id)", historyID: historyID,
            date: Date(timeIntervalSince1970: 1_000), snippet: "", sender: "sender@example.test",
            recipients: "recipient@example.test", cc: nil, subject: subject, sizeEstimate: size)
        let attachment = AttachmentRecord(accountID: accountID, messageID: id, partID: "1", attachmentID: attachmentID,
            filename: filename, mimeType: mimeType, size: size, isInline: false)
        try await cache.write { try $0.replaceLibraryAttachments([attachment], message: message, labelIDs: []) }
    }

    private func item(_ cache: MailCache, _ id: String) async throws -> AttachmentLibraryItem {
        try #require(try await cache.read { try $0.libraryAttachment(accountID: "a", messageID: id, partID: "1") })
    }
}
