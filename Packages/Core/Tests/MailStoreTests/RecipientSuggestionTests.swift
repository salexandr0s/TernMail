import Foundation
import GmailAPI
import GRDB
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

    @Test func matchingIgnoresCaseAndAccentsBeyondASCII() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            let saved = try JSONDecoder().decode([Person].self, from: Data(#"""
                [{"resourceName":"people/1","names":[{"displayName":"Élodie Martin"}],"emailAddresses":[{"value":"martin@example.com"}]}]
                """#.utf8))
            try tx.applyContactSync(saved, source: .connection, syncToken: "s", fields: "f", isFullSync: true, now: .now, accountID: "a")
            let others = try JSONDecoder().decode([Person].self, from: Data(#"""
                [{"resourceName":"otherContacts/1","names":[{"displayName":"ΓΙΏΡΓΟΣ Νικολάου"}],"emailAddresses":[{"value":"nikolaou@example.com"}]}]
                """#.utf8))
            try tx.applyContactSync(others, source: .other, syncToken: "o", fields: "f", isFullSync: true, now: .now, accountID: "a")
            _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: MessageRecord(
                accountID: "a", id: "m", threadID: "t", historyID: 1, date: .now, snippet: "",
                sender: "Γιώργος Παπαδόπουλος <giorgos@example.com>", recipients: "Élodie Durand <durand@example.com>",
                cc: nil, subject: "", sizeEstimate: 1
            ), labelIDs: [])])
        }
        #expect(try await cache.addressSuggestions(accountID: "a", matching: "γιώ").map(\.address) == ["giorgos@example.com"])
        #expect(try await cache.addressSuggestions(accountID: "a", matching: "élo").map(\.address) == ["durand@example.com"])
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "γιώ").map(\.address)
            == ["giorgos@example.com", "nikolaou@example.com"])
        for query in ["élo", "ÉLO", "elo"] {
            #expect(try await cache.recipientSuggestions(accountID: "a", matching: query).map(\.address)
                == ["durand@example.com", "martin@example.com"])
        }
    }

    @Test func cachedAddressesMatchBeforeAndAfterFoldingAndANewerCopyReplacesThem() async throws {
        let writer = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(writer, upTo: "body-size-v1")
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO message(accountID,id,threadID,historyID,date,snippet,sender,recipients,subject,sizeEstimate)
                VALUES ('a','m','t',1,0,'','Γιώργος <giorgos@example.com>','me@example.com','',0),
                    ('a','n','u',1,0,'','Νίκος <nikos@example.com>','me@example.com','',0);
                INSERT INTO contact(accountID,source,resourceName,displayName,updatedAt) VALUES ('a','connection','people/1','Élodie Martin',0);
                INSERT INTO contactEmail(accountID,source,resourceName,lowercasedAddress,address,isPrimary)
                VALUES ('a','connection','people/1','martin@example.com','Martin@example.com',1);
                """)
        }
        let cache = try MailCache(writer: writer)
        // Until the messages are folded, completion folds them as it reads.
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "γιώ").map(\.address) == ["giorgos@example.com"])
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "élo").map(\.address) == ["Martin@example.com"])
        // One message to a write, each continuing after the last.
        var folded: [Int64] = []
        while let last = try await cache.write({ [after = folded.last ?? 0] tx in
            try tx.foldPendingAddresses(accountID: "a", after: after, limit: 1)
        }) {
            folded.append(last)
        }
        #expect(folded == [1, 2])
        #expect(try await writer.read { db in try String.fetchAll(db, sql: "SELECT addressSearch FROM message") }.allSatisfy { !$0.isEmpty })
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "γιώ").map(\.address) == ["giorgos@example.com"])
        try await cache.write { tx in
            _ = try tx.upsertMessages([CacheTransaction.MessageUpdate(record: MessageRecord(
                accountID: "a", id: "m", threadID: "t", historyID: 2, date: Date(timeIntervalSince1970: 0), snippet: "",
                sender: "Ζωή <zoi@example.com>", recipients: "me@example.com", cc: nil, subject: "", sizeEstimate: 0
            ), labelIDs: [])])
        }
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "γιώ").isEmpty)
        #expect(try await cache.recipientSuggestions(accountID: "a", matching: "ζω").map(\.address) == ["zoi@example.com"])
    }

    @Test func aFoldWithNothingLeftReadsNoMessages() async throws {
        let few = try await foldCost(foldedMessages: 10)
        let many = try await foldCost(foldedMessages: 1_000)
        #expect(few.last == nil && many.last == nil)
        // Every launch folds each account. Reading the messages to find none
        // left would hold the writer for a scan of the whole table.
        #expect(many.instructions <= few.instructions + 1)
    }

    /// What one fold returns once every message is folded, and its SQLite
    /// instructions in hundreds.
    private func foldCost(foldedMessages: Int) async throws -> (last: Int64?, instructions: Int) {
        let cache = try MailCache.inMemory()
        return try await cache.write { tx in
            try tx.db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
                INSERT INTO message(accountID,id,threadID,historyID,date,snippet,sender,recipients,subject,sizeEstimate,addressSearch)
                SELECT 'a','m'||i,'t'||i,1,0,'','s@example.com','r@example.com','',1,'s@example.com'||char(10)||'r@example.com' FROM n
                """, arguments: [foldedMessages])
            var last: Int64?
            let cost = try instructions(tx.db) { last = try tx.foldPendingAddresses(accountID: "a", after: 0, limit: 500) }
            return (last, cost)
        }
    }
}
