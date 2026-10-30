import Foundation
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

    private func message(_ account: String) -> MessageRecord {
        MessageRecord(accountID: account, id: "m", threadID: "t", historyID: 1, date: .distantPast,
            snippet: "", sender: "sender@example.test", recipients: "me@example.test", cc: nil, subject: "Images", sizeEstimate: 1)
    }

    private func resource(_ account: String, id: String, data: Data = Data([1])) -> MIMEInlineResourceRecord {
        .init(accountID: account, messageID: "m", contentID: id, partID: id, mimeType: "image/png", data: data)
    }
}
