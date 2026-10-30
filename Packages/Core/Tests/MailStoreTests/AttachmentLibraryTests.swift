import Foundation
import GRDB
import Testing
@testable import MailStore

@Suite struct AttachmentLibraryTests {
    @Test func historyQueueMigrationPreservesAnExistingCheckpoint() async throws {
        let writer = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(writer, upTo: "attachment-library-v1")
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO attachmentIndexState (accountID,nextPageToken,historyID,indexedMessageCount,isComplete,failureCount)
                VALUES ('a','resume-here',100,25,0,0)
                """)
        }
        let cache = try MailCache(writer: writer)
        let state = try await cache.read { try $0.attachmentIndexState(accountID: "a") }
        #expect(state?.nextPageToken == "resume-here")
        #expect(state?.indexedMessageCount == 25)
        #expect(state?.pendingMessageIDs == [])
    }

    @Test func occurrencesSurviveCacheEvictionAndCategoriesSurviveRefresh() async throws {
        let cache = try MailCache.inMemory()
        let first = fixture("m1", account: "a")
        let second = fixture("m2", account: "a")
        let otherAccount = fixture("m1", account: "b")
        try await cache.write { tx in
            try tx.upsertMessages([.init(record: first, labelIDs: ["work"])])
            for message in [first, second, otherAccount] {
                try tx.replaceLibraryAttachments([file(message), file(message, part: "inline", inline: true)], message: message, labelIDs: ["work"])
            }
            try tx.setAttachmentCategory(.invoice, accountID: "a", messageID: "m1", partID: "1")
            try tx.deleteMessages(ids: ["m1"], accountID: "a")
            var newer = first
            newer.historyID += 1
            let replacement = file(newer, attachmentID: "refreshed-id")
            try tx.replaceLibraryAttachments([replacement, replacement], message: newer, labelIDs: ["paid"])
        }
        let page = try await cache.attachmentLibrary(query: .init(accountIDs: ["a", "b"]))
        #expect(page.totalCount == 3)
        #expect(Set(page.items.map(\.id)).count == 3)
        let corrected = try #require(page.items.first { $0.accountID == "a" && $0.messageID == "m1" })
        #expect(corrected.category == .invoice)
        #expect(corrected.attachmentID == "refreshed-id")
        #expect(corrected.labelIDs == ["paid"])
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: [])).items.isEmpty)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["b"])).totalCount == 1)
    }

    @Test func metadataFiltersAreCombinedScopedAndLiteral() async throws {
        let cache = try MailCache.inMemory()
        var invoice = fixture("invoice", account: "a", date: 1_000)
        invoice.sender = "Zoë Studio <billing@example.test>"
        invoice.subject = "Annual renewal"
        let receipt = fixture("receipt", account: "a", date: 2_000)
        let otherAccount = fixture("invoice", account: "b", date: 1_000)
        let fixtures = [invoice, receipt, otherAccount]
        try await cache.write { tx in
            for message in fixtures {
                let name = message.id == "invoice" ? "Invoice_100%.PDF" : "receipt.csv"
                try tx.replaceLibraryAttachments([file(message, name: name, size: message.id == "invoice" ? 400 : 700)],
                    message: message, labelIDs: ["work"])
                try tx.setAttachmentCategory(message.id == "invoice" ? .invoice : .receipt,
                    accountID: message.accountID, messageID: message.id, partID: "1")
            }
        }
        let query = AttachmentLibraryQuery(accountIDs: ["a", "b"], search: "100% annual", sender: "zoe",
            startDate: Date(timeIntervalSince1970: 1_000), endDate: Date(timeIntervalSince1970: 2_000),
            fileExtension: "PDF", category: .invoice, minimumSize: 400, maximumSize: 400,
            label: .init(accountID: "a", id: "work"))
        #expect(try await cache.attachmentLibrary(query: query).items.map(\.messageID) == ["invoice"])
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], search: "%")).totalCount == 1)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], search: "billing@example.test")).totalCount == 1)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], label: .init(accountID: "b", id: "work"))).items.isEmpty)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], endDate: Date(timeIntervalSince1970: 1_000))).items.isEmpty)
    }

    @Test func paginationHasStableTiesAndBounds() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            for index in 0..<13 {
                let message = fixture(String(format: "m%02d", index), account: "a", date: 1_000)
                try tx.replaceLibraryAttachments([file(message, size: index)], message: message, labelIDs: [])
            }
        }
        var ids: [String] = []
        for offset in stride(from: 0, to: 13, by: 4) {
            let page = try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], limit: 4, offset: offset))
            #expect(page.totalCount == 13)
            #expect(page.hasMore == (offset < 12))
            ids += page.items.map(\.id)
        }
        #expect(ids.count == 13)
        #expect(Set(ids).count == 13)
        let largest = try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], sort: .largest, limit: 1))
        #expect(largest.items.first?.size == 12)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["a"], limit: 0, offset: -1)).items.count == 1)
    }

    @Test func checkpointsAndCorrectionsPersistAndCommitWithTheirPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let cache = try MailCache.open(at: url)
        let message = fixture("old", account: "a")
        try await cache.write { tx in
            try tx.replaceLibraryAttachments([file(message)], message: message, labelIDs: [], generation: "scan-1")
            try tx.setAttachmentCategory(.contract, accountID: "a", messageID: "old", partID: "1")
            var state = AttachmentIndexState(accountID: "a")
            state.nextPageToken = "page-2"
            state.historyID = 100
            state.historyPageToken = "history-2"
            state.pendingMessageIDs = ["queued-1", "queued-2"]
            state.indexedMessageCount = 25
            state.generation = "scan-1"
            try tx.saveAttachmentIndexState(state)
        }
        enum Interrupted: Error { case page }
        do {
            try await cache.write { tx in
                let unfinished = fixture("unfinished", account: "a")
                try tx.replaceLibraryAttachments([file(unfinished)], message: unfinished, labelIDs: [], generation: "scan-1")
                var state = AttachmentIndexState(accountID: "a")
                state.isComplete = true
                try tx.saveAttachmentIndexState(state)
                throw Interrupted.page
            }
            Issue.record("The interrupted page should throw")
        } catch Interrupted.page { }
        let reopened = try MailCache.open(at: url)
        let state = try await reopened.read { try $0.attachmentIndexState(accountID: "a") }
        #expect(state?.nextPageToken == "page-2")
        #expect(state?.historyPageToken == "history-2")
        #expect(state?.pendingMessageIDs == ["queued-1", "queued-2"])
        #expect(state?.indexedMessageCount == 25)
        #expect(state?.isComplete == false)
        let page = try await reopened.attachmentLibrary(query: .init(accountIDs: ["a"]))
        #expect(page.items.map(\.messageID) == ["old"])
        #expect(page.items.first?.category == .contract)
    }

    @Test func generationsAndHistoryReconcileWithoutCrossingAccounts() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            for account in ["a", "b"] {
                for id in ["keep", "gone"] {
                    let message = fixture(id, account: account)
                    try tx.replaceLibraryAttachments([file(message)], message: message, labelIDs: ["old"], generation: "old")
                }
                try tx.saveAttachmentIndexState(.init(accountID: account))
            }
            try tx.applyLibraryLabelChange(messageID: "keep", added: ["new"], removed: ["old"], historyID: 200, accountID: "a")
            // An older page still proves the occurrence exists, but must not restore old labels.
            let oldCopy = fixture("keep", account: "a")
            try tx.replaceLibraryAttachments([file(oldCopy)], message: oldCopy, labelIDs: ["old"], generation: "new")
            try tx.finishLibraryGeneration(accountID: "a", generation: "new")
        }
        let a = try await cache.attachmentLibrary(query: .init(accountIDs: ["a"]))
        #expect(a.items.map(\.messageID) == ["keep"])
        #expect(a.items.first?.labelIDs == ["new"])
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["b"])).totalCount == 2)
        try await cache.write { tx in
            try tx.deleteAccountData(accountID: "a")
            try tx.deleteLibraryAttachments(messageIDs: ["gone"], accountID: "b")
        }
        #expect(try await cache.read { try $0.cachedAccountIDs() } == ["b"])
        #expect(try await cache.read { try $0.attachmentIndexState(accountID: "a") } == nil)
        #expect(try await cache.attachmentLibrary(query: .init(accountIDs: ["b"])).totalCount == 1)
    }
}

private func fixture(_ id: String, account: String, date: TimeInterval = 1_000) -> MessageRecord {
    MessageRecord(accountID: account, id: id, threadID: "thread-\(id)", historyID: 100,
        date: Date(timeIntervalSince1970: date), snippet: "", sender: "Example <sender@example.test>",
        recipients: "recipient@example.test", cc: nil, subject: "Example email", sizeEstimate: 1_000)
}

private func file(_ message: MessageRecord, part: String = "1", name: String = "invoice.pdf", size: Int = 400,
                  inline: Bool = false, attachmentID: String = "download-id") -> AttachmentRecord {
    AttachmentRecord(accountID: message.accountID, messageID: message.id, partID: part,
        attachmentID: attachmentID, filename: name, mimeType: "application/pdf", size: size, isInline: inline)
}
