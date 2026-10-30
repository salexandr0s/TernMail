import Foundation
import GmailAPI
import MessageContent
import Testing
@testable import MailStore

@Suite struct ComposePreferenceTests {
    @Test func exactSignatureAssignmentOverridesAccountDefaultsAndDeletionClearsIt() async throws {
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "a", email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: .now))
        let signature = LocalSignature(id: "local", name: "Local", document: ComposeDocument(plainText: "Local signature"))
        try await store.saveLocalSignature(signature)
        try await store.saveSignatureAssignment(SignatureAssignment(accountID: "a", newMessages: .local(id: signature.id),
                                                                    replies: .local(id: signature.id), placeAboveQuote: false, includeSeparator: false))
        try await store.saveSignatureAssignment(SignatureAssignment(accountID: "a", address: "alias@example.com", newMessages: .none))
        let inherited = try await store.composeSignature(accountID: "a", address: "me@example.com", kind: .reply)
        #expect(inherited.html?.contains("Local signature") == true)
        #expect(!inherited.aboveQuote && !inherited.separator)
        #expect(try await store.composeSignature(accountID: "a", address: "alias@example.com", kind: .new).html == nil)
        try await store.deleteLocalSignature(id: signature.id)
        #expect(try await store.composeSignature(accountID: "a", address: "me@example.com", kind: .new).html == nil)
    }

    @Test func latestCorrespondenceUsesExactAddressesWithinAllowedAccounts() async throws {
        let cache = try MailCache.inMemory()
        let records = [
            ("a", "pat@example.com", 1.0), ("b", "pat@example.com", 2.0),
            ("a", "notpat@example.com", 3.0), ("c", "pat@example.com", 4.0),
        ]
        try await cache.write { tx in
            for (index, entry) in records.enumerated() {
                _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: MessageRecord(
                    accountID: entry.0, id: "m\(index)", threadID: "t", historyID: 1, date: Date(timeIntervalSince1970: entry.2),
                    snippet: "", sender: entry.1, recipients: "", cc: nil, subject: "", sizeEstimate: 0
                ), labelIDs: [])])
            }
        }
        #expect(try await cache.lastCorrespondenceAccount(with: "PAT@example.com", accountIDs: ["a", "b"]) == "b")
        #expect(try await cache.lastCorrespondenceAccount(with: "pat@example.com", accountIDs: ["a"]) == "a")
        #expect(try await cache.lastCorrespondenceAccount(with: "pat@example.com", accountIDs: []) == nil)
    }
}
