import Foundation
import GmailAPI
import Testing
@testable import MailStore

@Suite struct ContactEnrichmentStoreTests {
    @Test func photosFollowContactSourceAndRejectLateWritesAfterDisableAndReenable() async throws {
        let cache = try MailCache.inMemory()
        let people = try decodePeople()
        try await cache.write { tx in
            for account in ["a", "b"] {
                try tx.applyEnrichedContactSync(people, source: .connection, syncToken: "1", fields: PeopleClient.fields,
                    isFullSync: true, now: .now, accountID: account)
                try tx.applyEnrichedContactSync(people, source: .other, syncToken: "1", fields: PeopleClient.fields,
                    isFullSync: true, now: .now, accountID: account)
            }
        }
        let old = try #require(try await cache.contactPhoto(accountID: "a", address: "ME@EXAMPLE.TEST"))
        #expect(old.source == .connection)
        #expect(try await cache.storeContactPhoto(Data([1]), for: old))
        try await cache.write { try $0.deleteContacts(accountID: "a") }
        #expect(try await cache.contactPhoto(accountID: "a", address: "me@example.test") == nil)
        #expect(try await cache.contactPhoto(accountID: "b", address: "me@example.test") != nil)
        try await cache.write { tx in
            try tx.applyEnrichedContactSync(people, source: .connection, syncToken: "new", fields: PeopleClient.fields,
                isFullSync: true, now: .now, accountID: "a")
        }
        #expect(try await !cache.storeContactPhoto(Data([2]), for: old))
        let fresh = try #require(try await cache.contactPhoto(accountID: "a", address: "me@example.test"))
        #expect(fresh.version != old.version)
        #expect(fresh.data == nil)
    }

    @Test func groupSuggestionsAreLiteralAccountScopedAndCascadeWithContacts() async throws {
        let cache = try MailCache.inMemory()
        let people = try decodePeople()
        let groups = try JSONDecoder().decode([GoogleContactGroup].self, from: Data(#"[{"resourceName":"contactGroups/a","name":"Te%am","groupType":"USER_CONTACT_GROUP","memberCount":2},{"resourceName":"contactGroups/b","name":"Team","groupType":"USER_CONTACT_GROUP","memberCount":1}]"#.utf8))
        try await cache.write { tx in
            for account in ["a", "b"] {
                try tx.applyEnrichedContactSync(people, source: .connection, syncToken: "1", fields: PeopleClient.fields, isFullSync: true, now: .now, accountID: account)
                try tx.replaceContactGroups(.init(groups: groups, isComplete: false), accountID: account, at: .now)
            }
        }
        let match = try await cache.contactGroupSuggestions(accountID: "a", matching: "Te%")
        #expect(match.map(\.name) == ["Te%am"])
        #expect(match.allSatisfy { $0.accountID == "a" && !$0.isComplete })
        let generation = try #require(try await cache.read { try $0.contactEnrichmentGeneration(accountID: "a") })
        try await cache.write { try $0.deleteContacts(accountID: "a") }
        #expect(try await cache.contactGroupSuggestions(accountID: "a", matching: "Te").isEmpty)
        #expect(try await cache.contactGroupSuggestions(accountID: "b", matching: "Te").count == 2)
        try await cache.write { tx in
            try tx.applyEnrichedContactSync(people, source: .connection, syncToken: "2", fields: PeopleClient.fields, isFullSync: true, now: .now, accountID: "a")
        }
        #expect(try await cache.read { try $0.contactEnrichmentGeneration(accountID: "a") } != generation)
    }

    private func decodePeople() throws -> [Person] {
        try JSONDecoder().decode([Person].self, from: Data(#"[{"resourceName":"people/a","emailAddresses":[{"value":"me@example.test"}],"photos":[{"url":"https://lh3.googleusercontent.com/person","default":false}]}]"#.utf8))
    }
}
