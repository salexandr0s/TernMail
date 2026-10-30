import Foundation
import Testing
@testable import MailStore

@Suite struct AccountObservationTests {
    @Test(.timeLimit(.minutes(1))) func featureChangesArriveWithoutReplacingTheMailbox() async throws {
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "account", email: "me@example.com", displayName: nil,
            grantedScopes: [], addedAt: .now))
        var iterator = store.accountChanges(id: "account").makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial?.enabledFeatures == [])
        try await store.updateAccount(id: "account") { $0.enabledFeatures = ["gmailSettings"] }
        let enabled = try #require(try await iterator.next())
        #expect(enabled?.enabledFeatures == ["gmailSettings"])
        try await store.updateAccount(id: "account") { $0.enabledFeatures = [] }
        let disabled = try #require(try await iterator.next())
        #expect(disabled?.enabledFeatures == [])
        try await store.deleteAccount(id: "account")
        let removed = try #require(try await iterator.next())
        #expect(removed == nil)
    }
}
