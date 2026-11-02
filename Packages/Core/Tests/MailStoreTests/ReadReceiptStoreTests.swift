import Foundation
import MessageContent
import Testing
@testable import MailStore

@Suite struct ReadReceiptStoreTests {
    private let timestamp = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func draftOptionPersistsAndOlderEncodedDraftsDefaultOff() async throws {
        let cache = try MailCache.inMemory()
        let original = draft()
        try await cache.write { try $0.insertLocalDraft(original) }
        #expect(try await cache.read { try $0.localDraft(id: original.id)?.content.requestsReadReceipt } == true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "requestsReadReceipt")
        let restored = try JSONDecoder().decode(LocalDraft.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!restored.requestsReadReceipt)
        var edited = original.content
        edited.requestsReadReceipt = false
        let content = edited
        try await cache.write { _ = try $0.updateLocalDraft(id: original.id, content: content, now: timestamp) }
        #expect(try await cache.read { try $0.localDraft(id: original.id)?.requestsReadReceipt } == false)
    }

    @Test func earlyReceiptsMatchOnlySentRequestsAndAreDeduplicatedAndAccountScoped() async throws {
        let cache = try MailCache.inMemory()
        let request = draft()
        let event = ReadReceipt(originalMessageID: request.rfcMessageID, recipient: "reader@example.com", disposition: .displayed)
        try await cache.write { tx in
            try tx.storeReadReceipt(event, accountID: "a", receiptMessageID: "receipt", reporter: "reader@example.com",
                returnAddresses: ["sender@example.com"], receivedAt: timestamp)
        }
        #expect(try await cache.readReceiptStatuses(accountID: "a").isEmpty)
        try await cache.write { tx in
            try tx.recordReadReceiptRequest(for: request, senderAddress: "sender@example.com", messageID: "sent", threadID: "t", sentAt: timestamp)
            try tx.storeReadReceipt(event, accountID: "a", receiptMessageID: "receipt", reporter: "reader@example.com",
                returnAddresses: ["sender@example.com"], receivedAt: timestamp.addingTimeInterval(10))
        }
        let statuses = try await cache.readReceiptStatuses(accountID: "a", recipient: "READER@example.com")
        #expect(statuses.count == 1)
        #expect(statuses.first?.recipients.first?.receivedAt == timestamp)
        #expect(try await cache.readReceiptStatuses(accountID: "b").isEmpty)
        try await cache.write { try $0.deleteAccountData(accountID: "a") }
        #expect(try await cache.readReceiptStatuses(accountID: "a").isEmpty)
        #expect(try await cache.read { try $0.hasReadReceiptEvent(accountID: "a", receiptMessageID: "receipt") } == false)
    }

    @Test func unrelatedReportsCannotConfirmARequest() async throws {
        let cache = try MailCache.inMemory()
        let request = draft()
        try await cache.write { tx in
            try tx.recordReadReceiptRequest(for: request, senderAddress: "sender@example.com", messageID: nil, threadID: nil, sentAt: timestamp)
            let cases: [(String, String, String, String, String, ReadReceipt.Disposition)] = [
                ("wrong-account", "b", request.rfcMessageID, "reader@example.com", "sender@example.com", .displayed),
                ("wrong-message", "a", "<other@example.com>", "reader@example.com", "sender@example.com", .displayed),
                ("wrong-recipient", "a", request.rfcMessageID, "other@example.com", "sender@example.com", .displayed),
                ("wrong-return", "a", request.rfcMessageID, "reader@example.com", "other@example.com", .displayed),
                ("processed", "a", request.rfcMessageID, "reader@example.com", "sender@example.com", .processed),
            ]
            for (id, account, message, recipient, target, disposition) in cases {
                try tx.storeReadReceipt(ReadReceipt(originalMessageID: message, recipient: recipient, disposition: disposition),
                    accountID: account, receiptMessageID: id, reporter: recipient, returnAddresses: [target], receivedAt: timestamp)
            }
            try tx.storeReadReceipt(ReadReceipt(originalMessageID: request.rfcMessageID, recipient: "reader@example.com", disposition: .displayed),
                accountID: "a", receiptMessageID: "wrong-reporter", reporter: "other@example.com", returnAddresses: ["sender@example.com"], receivedAt: timestamp)
        }
        #expect(try await cache.readReceiptStatuses(accountID: "a").first?.recipients.first?.receivedAt == nil)
    }

    private func draft() -> LocalDraft {
        LocalDraft(accountID: "a", kind: .new,
            content: DraftContent(to: [EmailAddress(address: "reader@example.com")], requestsReadReceipt: true),
            rfcMessageID: "<request@example.com>", now: timestamp)
    }
}
