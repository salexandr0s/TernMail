import Foundation
import GRDB
import Testing
@testable import MailStore

private let account = "acct"

@Suite struct MailListPageTests {
    @Test func aPageChangesOnlyWithTheConversationsItShows() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.rebuildThreads(try tx.upsertMessages([
                message("m1", thread: "t1", labels: [SystemLabel.inbox]),
                message("m2", thread: "t2", labels: [SystemLabel.inbox], minutes: 5),
                message("m3", thread: "t3", labels: ["Label_1"], minutes: 10),
            ]), accountID: account)
        }
        let inbox = MailListPageBuilder.mailbox(accountIDs: [account], labelID: SystemLabel.inbox, limit: 50)
        let first = try await cache.read { tx in try inbox.page(in: tx) }
        #expect(first.threads.map(\.id) == ["t2", "t1"])
        #expect(first.entries.map(\.message.id) == ["m2", "m1"])

        // News in a conversation the page doesn't show leaves it as it was.
        try await cache.write { tx in
            try tx.rebuildThreads(try tx.upsertMessages([
                message("m4", thread: "t3", labels: ["Label_1"], minutes: 15),
            ]), accountID: account)
        }
        let afterElsewhere = try await cache.read { tx in try inbox.page(in: tx) }
        #expect(afterElsewhere == first)
        #expect(afterElsewhere.fingerprint == first.fingerprint)

        // A star on one of its messages changes it.
        try await cache.write { tx in
            try tx.rebuildThreads(try tx.upsertMessages([
                message("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.starred], history: 101),
            ]), accountID: account)
        }
        let afterStar = try await cache.read { tx in try inbox.page(in: tx) }
        #expect(afterStar.fingerprint != first.fingerprint)
        #expect(afterStar.entries.first { $0.message.id == "m1" }?.labels.contains(SystemLabel.starred) == true)
    }

    @Test func searchResultsShowTheirConversationsAsTheCacheHoldsThem() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.rebuildThreads(try tx.upsertMessages([
                message("m1", thread: "t1"),
                message("m2", thread: "t2", minutes: 5),
                message("m3", thread: "t3", minutes: 10),
            ]), accountID: account)
        }
        let found = try await cache.read { tx in
            try MailListPageBuilder.mailbox(accountIDs: [account], labelID: SystemLabel.inbox, limit: 50).page(in: tx).threads
        }
        #expect(found.map(\.id) == ["t3", "t2", "t1"])

        // A reply arrives in t1 and t2 goes away after the search answered.
        try await cache.write { tx in
            var changed = try tx.upsertMessages([message("m4", thread: "t1", minutes: 15)])
            changed.formUnion(try tx.deleteMessages(ids: ["m2"], accountID: account))
            try tx.rebuildThreads(changed, accountID: account)
        }
        let page = try await cache.read { tx in try MailListPageBuilder.searchResults(found, matching: nil).page(in: tx) }
        // The order the search gave, with each row as it is now.
        #expect(page.threads.map(\.id) == ["t3", "t1"])
        #expect(page.threads.map(\.messageCount) == [1, 2])
        #expect(Set(page.entries.map(\.message.id)) == ["m1", "m3", "m4"])
    }

    @Test func ownAddressesMarkMailAddressedToTheAccount() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.setOwnAddresses(["Me@Example.com"], accountID: account)
            _ = try tx.upsertMessages([
                message("to", to: "Me <me@example.com>"),
                message("cc", to: "team@example.com", cc: "ME@example.com"),
                message("alias", to: "alias@example.com"),
                message("other", to: "pat@example.com"),
            ])
        }
        #expect(try await marked(cache) == ["to", "cc"])

        // A new address marks the mail already cached.
        try await cache.write { tx in
            try tx.setOwnAddresses(["me@example.com", "alias@example.com"], accountID: account)
        }
        #expect(try await marked(cache) == ["to", "cc", "alias"])

        // The same addresses again, in another case, write nothing.
        let writes = try await cache.write { tx -> Int in
            let before = tx.db.totalChangesCount
            try tx.setOwnAddresses(["ALIAS@example.com", "me@example.com"], accountID: account)
            return tx.db.totalChangesCount - before
        }
        #expect(writes == 0)

        // Dropping one unmarks its mail.
        try await cache.write { tx in try tx.setOwnAddresses(["alias@example.com"], accountID: account) }
        #expect(try await marked(cache) == ["alias"])
    }
}

private func marked(_ cache: MailCache) async throws -> Set<String> {
    try await cache.read { tx in
        try String.fetchSet(tx.db, sql: "SELECT id FROM message WHERE accountID = ? AND addressedToMe", arguments: [account])
    }
}

private func message(
    _ id: String, thread: String? = nil, labels: [String] = [SystemLabel.inbox], to: String = "r@example.com",
    cc: String? = nil, minutes: Double = 0, history: Int64 = 100
) -> CacheTransaction.MessageUpdate {
    CacheTransaction.MessageUpdate(
        record: MessageRecord(
            accountID: account, id: id, threadID: thread ?? id, historyID: history,
            date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60),
            snippet: "Snippet", sender: "Sender <s@example.com>", recipients: to,
            cc: cc, subject: "Subject", sizeEstimate: 1
        ),
        labelIDs: labels
    )
}
