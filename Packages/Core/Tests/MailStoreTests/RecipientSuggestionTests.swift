import Foundation
import GmailAPI
import MessageContent
import Testing
@testable import MailStore

@Suite struct RecipientSuggestionTests {
    @Test func cachedMailKeepsItsRankAndSavedContactsSupplyNamesWithoutDuplicates() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            let people = try JSONDecoder().decode([Person].self, from: Data(#"""
                [{"resourceName":"people/1","names":[{"displayName":"Pat Saved"}],"emailAddresses":[{"value":"PAT@example.com"}]},
                 {"resourceName":"people/2","names":[{"displayName":"Pat Contact"}],"emailAddresses":[{"value":"contact@example.com"}]}]
                """#.utf8))
            try tx.applyContactSync(people, source: .connection, syncToken: "s", fields: "f", isFullSync: true, now: .now, accountID: "a")
            let others = try JSONDecoder().decode([Person].self, from: Data(#"""
                [{"resourceName":"otherContacts/1","names":[{"displayName":"Pat Other"}],"emailAddresses":[{"value":"pat@example.com"}]},
                 {"resourceName":"otherContacts/2","names":[{"displayName":"Pat Last"}],"emailAddresses":[{"value":"last@example.com"}]}]
                """#.utf8))
            try tx.applyContactSync(others, source: .other, syncToken: "o", fields: "f", isFullSync: true, now: .now, accountID: "a")
            for index in 0..<2 {
                _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: MessageRecord(
                    accountID: "a", id: "m\(index)", threadID: "t", historyID: 1, date: Date(timeIntervalSince1970: Double(index)),
                    snippet: "", sender: "Pat Mail <pat@example.com>", recipients: index == 0 ? "Pat Frequent <frequent@example.com>" : "",
                    cc: nil, subject: "", sizeEstimate: 1
                ), labelIDs: [])])
            }
        }
        let found = try await cache.recipientSuggestions(accountID: "a", matching: "pat")
        #expect(found.map(\.normalized) == ["pat@example.com", "frequent@example.com", "contact@example.com", "last@example.com"])
        #expect(found.first?.name == "Pat Saved")
        #expect(try await cache.recipientSuggestions(accountID: "b", matching: "pat").isEmpty)
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "pat", includeContacts: false).count == 2)
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "pat", excluding: ["pat@example.com"]).count == 3)
    }

    @Test func contactPrefixesLeadMailSubstringMatchesAndWildcardsAreLiteral() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            let people = try JSONDecoder().decode([Person].self, from: Data(#"""
                [{"resourceName":"people/1","names":[{"displayName":"Pat"}],"emailAddresses":[{"value":"first@example.com"}]},
                 {"resourceName":"people/2","names":[{"displayName":"100%"}],"emailAddresses":[{"value":"literal@example.com"}]}]
                """#.utf8))
            try tx.applyContactSync(people, source: .connection, syncToken: "s", fields: "f", isFullSync: true, now: .now, accountID: "a")
            _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: MessageRecord(
                accountID: "a", id: "m", threadID: "t", historyID: 1, date: .now, snippet: "", sender: "xxpat@example.com",
                recipients: "", cc: nil, subject: "", sizeEstimate: 1
            ), labelIDs: [])])
        }
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "pat").map(\.address)
            == ["first@example.com", "xxpat@example.com"])
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "%").map(\.address) == ["literal@example.com"])
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: " ").isEmpty)
    }
}
