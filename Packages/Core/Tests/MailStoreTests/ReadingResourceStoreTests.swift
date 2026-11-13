import Foundation
import GRDB
import Testing
@testable import MailStore

@Suite struct ReadingResourceStoreTests {
    @Test func resourcesAreCaseSensitiveAndScopedToTheirMessageAndAccount() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            for account in ["a", "b"] {
                try tx.upsertMessages([.init(record: message(account), labelIDs: [])])
                try tx.replaceMIMEResources([resource(account, id: "<Image@Example>", data: Data(account.utf8)),
                    resource(account, id: "image@example", data: Data([2]))], messageID: "m", accountID: account)
            }
        }
        #expect(try await cache.mimeResources(messageID: "m", accountID: "a").map(\.contentID) == ["Image@Example", "image@example"])
        #expect(try await cache.mimeResources(messageID: "m", accountID: "a").first?.data == Data("a".utf8))
        #expect(try await cache.mimeResources(messageID: "m", accountID: "b").first?.data == Data("b".utf8))
        #expect(try await cache.mimeResources(messageID: "unknown", accountID: "a").isEmpty)
        try await cache.write { tx in _ = try tx.deleteMessages(ids: ["m"], accountID: "a") }
        #expect(try await cache.mimeResources(messageID: "m", accountID: "a").isEmpty)
        #expect(try await cache.mimeResources(messageID: "m", accountID: "b").count == 2)
    }

    @Test func invalidReplacementLeavesThePreviousMapIntact() async throws {
        let cache = try MailCache.inMemory()
        let original = resource("a", id: "image")
        try await cache.write { tx in
            try tx.upsertMessages([.init(record: message("a"), labelIDs: [])])
            try tx.replaceMIMEResources([original], messageID: "m", accountID: "a")
        }
        let duplicate = [original, resource("a", id: "<image>")]
        let wrongAccount = [resource("b", id: "other")]
        var svg = original
        svg.mimeType = "image/svg+xml"
        let malicious = svg
        let tooMany = (0..<33).map { resource("a", id: "image\($0)") }
        let oversized = resource("a", id: "large", data: Data(repeating: 0, count: MIMEInlineResourceRecord.maximumResourceBytes + 1))
        let largePart = Data(repeating: 0, count: MIMEInlineResourceRecord.maximumResourceBytes)
        let excessiveTotal = (0..<5).map { resource("a", id: "part\($0)", data: largePart) }
        for batch in [duplicate, wrongAccount, [malicious], tooMany, [oversized], excessiveTotal] {
            await #expect(throws: ReadingResourceError.self) {
                try await cache.write { try $0.replaceMIMEResources(batch, messageID: "m", accountID: "a") }
            }
            #expect(try await cache.mimeResources(messageID: "m", accountID: "a") == [original])
        }
    }

    @Test func openingReadMatchesTheObservationsForNamedMessagesThatHaveBodies() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            var unsaved = message("a")
            unsaved.id = "unsaved"
            try tx.upsertMessages([.init(record: message("a"), labelIDs: []), .init(record: unsaved, labelIDs: [])])
            try tx.saveBodies([.init(accountID: "a", messageID: "m", html: "<p>Body</p>", plainText: nil, fetchedAt: .distantPast)])
            try tx.replaceMIMEResources([resource("a", id: "image")], messageID: "m", accountID: "a")
            try tx.rebuildThreads(["t"], accountID: "a")
        }
        let opening = try await cache.readingThreadOpening(accountID: "a", threadID: "t") { $0.messages.map(\.id) + ["elsewhere"] }
        var details = cache.thread(accountID: "a", threadID: "t").makeAsyncIterator()
        var resources = cache.readingResources(messageID: "m", accountID: "a").makeAsyncIterator()
        // The reader skips an observation's first value when it equals this read.
        #expect(try await details.next() == .some(opening.detail))
        #expect(try await resources.next() == opening.resources["m"])
        #expect(opening.detail?.messages.map(\.id).sorted() == ["m", "unsaved"])
        #expect(Array(opening.resources.keys) == ["m"])
        let missing = try await cache.readingThreadOpening(accountID: "a", threadID: "missing") { _ in ["m"] }
        #expect(missing.detail == nil)
        #expect(missing.resources.isEmpty)
    }

    @Test func upgradeKeepsEnrichmentMarksInTheirOwnRows() async throws {
        let writer = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(writer, upTo: "address-search-v1")
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let sent = LocalSend.messageID(localDraftID: "sent")
        try await writer.write { db in
            for id in ["opened", "unopened", sent] {
                try db.execute(sql: """
                    INSERT INTO message(accountID,id,threadID,historyID,date,snippet,sender,recipients,subject,sizeEstimate)
                    VALUES ('a',?,'t',1,0,'','sender@example.test','me@example.test','',0)
                    """, arguments: [id])
                try db.execute(sql: "INSERT INTO messageBody(accountID,messageID,plainText,fetchedAt,enrichedAt) VALUES ('a',?,'Body',0,?)",
                               arguments: [id, id == "unopened" ? nil : date])
            }
            try LocalDraft(id: "draft", accountID: "a", kind: .new, rfcMessageID: "<draft@example.test>", now: date).insert(db)
            _ = try CacheTransaction(db: db).enqueue(.modifyMessages, accountID: "a", messageIDs: ["opened"], add: [SystemLabel.starred],
                                                     now: date, notBefore: date)
        }
        let cache = try MailCache(writer: writer)
        #expect(try await cache.read { try $0.bodyEnrichedAt(messageID: "opened", accountID: "a") } == date)
        #expect(try await cache.read { try $0.bodyEnrichedAt(messageID: sent, accountID: "a") } == date)
        #expect(try await cache.read { try $0.unenrichedBodyMessageIDs(threadID: "t", accountID: "a") } == ["unopened"])
        #expect(try await cache.cacheResetReadiness() == CacheResetReadiness(localDraftCount: 1, activeActionCount: 1, failedActionCount: 0))
        try await cache.write { tx in
            // Saving a body again keeps its mark, and a missing body can't get one.
            try tx.saveBodies([.init(accountID: "a", messageID: "opened", html: "<p>Body</p>", plainText: nil, fetchedAt: date)])
            try tx.setBodyEnrichedAt(date, messageID: "missing", accountID: "a")
            try tx.setBodyEnrichedAt(nil, messageID: sent, accountID: "a")
        }
        #expect(try await cache.read { try $0.bodyEnrichedAt(messageID: "opened", accountID: "a") } == date)
        #expect(try await cache.read { try $0.bodyEnrichedAt(messageID: "missing", accountID: "a") } == nil)
        #expect(Set(try await cache.read { try $0.unenrichedBodyMessageIDs(threadID: "t", accountID: "a") }) == ["unopened", sent])
        try await cache.write { tx in _ = try tx.deleteMessages(ids: ["opened"], accountID: "a") }
        #expect(try await cache.read { try Int.fetchOne($0.db, sql: "SELECT COUNT(*) FROM messageBodyEnrichment") } == 0)
    }

    private func message(_ account: String) -> MessageRecord {
        MessageRecord(accountID: account, id: "m", threadID: "t", historyID: 1, date: .distantPast,
            snippet: "", sender: "sender@example.test", recipients: "me@example.test", cc: nil, subject: "Images", sizeEstimate: 1)
    }

    private func resource(_ account: String, id: String, data: Data = Data([1])) -> MIMEInlineResourceRecord {
        .init(accountID: account, messageID: "m", contentID: id, partID: id, mimeType: "image/png", data: data)
    }
}
