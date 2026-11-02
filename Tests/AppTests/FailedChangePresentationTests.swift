import Foundation
import MailStore
import Testing
@testable import Tern

@Suite struct FailedChangePresentationTests {
    @Test func recoveryNamesTheExactAccountMessageAndKeepsItsSourceLink() async throws {
        let cache = try MailCache.inMemory()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let resolved = try await cache.write { transaction in
            for (account, subject) in [("first", "Travel receipt"), ("second", "Project review")] {
                _ = try transaction.upsertMessages([.init(record: MessageRecord(accountID: account, id: "same-message",
                    threadID: "same-thread", historyID: 1, date: now, snippet: "", sender: "sender@example.invalid",
                    recipients: "me@example.invalid", cc: nil, subject: subject, sizeEstimate: 1), labelIDs: ["INBOX"])])
                try transaction.rebuildThreads(["same-thread"], accountID: account)
            }
            let enqueued = try transaction.enqueue(.modifyMessages, accountID: "second",
                messageIDs: ["same-message"], add: ["STARRED"], now: now, notBefore: now)
            let action = try #require(enqueued)
            return try FailedChangePresentation.resolve(action, in: transaction)
        }
        #expect(resolved.targetDescription == "Project review")
        #expect(resolved.intentDescription == "Add: Starred")
        #expect(resolved.sources.count == 1)
        #expect(resolved.sources.first?.link.accountID == "second")
        #expect(resolved.sources.first?.link.messageID == "same-message")
        #expect(resolved.action.createdAt == now)
    }

    @Test func missingSourceAndSettingsIntentStillHaveUsefulDescriptions() async throws {
        let cache = try MailCache.inMemory()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let descriptions = try await cache.write { transaction in
            let enqueued = try transaction.enqueue(.modifyMessages, accountID: "first",
                messageIDs: ["opaque-one", "opaque-two"], add: ["STARRED"], now: now, notBefore: now, compensating: true)
            let missing = try #require(enqueued)
            let signature = try transaction.enqueueSettingsChange(.signature(address: "alias@example.invalid", html: "", previousHTML: ""),
                accountID: "first", now: now, notBefore: now)
            let label = try transaction.enqueueLabelChange(.createLabel, labelID: "temporary-label",
                change: .init(newName: "Receipts"), accountID: "first", now: now, notBefore: now)
            return try [missing, signature, label].map { try FailedChangePresentation.resolve($0, in: transaction) }
        }
        #expect(descriptions[0].targetDescription == "2 messages · Originals are no longer cached")
        #expect(descriptions[0].sources.isEmpty)
        #expect(!descriptions[0].targetDescription.contains("opaque"))
        #expect(descriptions[1].targetDescription == "Signature for alias@example.invalid")
        #expect(descriptions[2].targetDescription == "Receipts")
    }
}
