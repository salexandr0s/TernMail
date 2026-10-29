import Foundation
import GRDB
import Testing
@testable import MailStore
import MessageContent

private let acct = "acct"

@Suite struct SearchIndexTests {
    @Test func indexFollowsInsertsUpdatesDeletesAndBodies() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [
            stored("m1", thread: "t1", subject: "Trail map", sender: "Ann Lee <ann@example.com>"),
            stored("m2", thread: "t2", subject: "Lunch"),
        ])
        #expect(try await search(cache, "trail") == ["t1"])
        #expect(try await search(cache, "ann") == ["t1"])

        try await seed(cache, [stored("m1", thread: "t1", subject: "Lake plan", historyID: 200)])
        #expect(try await search(cache, "trail").isEmpty)
        #expect(try await search(cache, "lake") == ["t1"])

        try await cache.write { tx in
            try tx.saveBodies([MessageBodyRecord(
                accountID: acct, messageID: "m2", html: "<p>Meet at the <b>summit</b> café</p>", plainText: nil, fetchedAt: .now
            )])
        }
        #expect(try await search(cache, "cafe summit") == ["t2"])

        try await cache.write { tx in try tx.rebuildThreads(tx.deleteMessages(ids: ["m2"], accountID: acct), accountID: acct) }
        #expect(try await search(cache, "summit").isEmpty)
        try await checkIntegrity(cache)
    }

    @Test func labelOnlyChangesLeaveTheIndexRowAlone() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [stored("m1", thread: "t1", subject: "Trail map")])
        try await cache.writer.write { db in
            try db.execute(sql: """
                CREATE TEMP TABLE textWrites (messageID TEXT);
                CREATE TEMP TRIGGER watchText AFTER UPDATE ON main.messageText BEGIN
                    INSERT INTO textWrites VALUES (NEW.messageID);
                END;
                """)
        }
        try await cache.write { tx in
            _ = try tx.applyLabelChange(messageID: "m1", added: [SystemLabel.starred], removed: [], historyID: 150, accountID: acct)
            try tx.upsertMessages([stored("m1", thread: "t1", subject: "Trail map", labels: [], historyID: 160)])
        }
        #expect(try await textWrites(cache).isEmpty)

        try await seed(cache, [stored("m1", thread: "t1", subject: "Trail map v2", historyID: 170)])
        #expect(try await textWrites(cache) == ["m1"])
        try await checkIntegrity(cache)
    }

    @Test func migrationIndexesAnExistingCache() async throws {
        let queue = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(queue, upTo: "compose-v1")
        try await queue.write { db in
            try CacheTransaction(db: db).upsertMessages([stored("m1", thread: "t1", subject: "Trail map")])
            try CacheTransaction(db: db).rebuildThreads(["t1"], accountID: acct)
            try MessageBodyRecord(accountID: acct, messageID: "m1", html: nil, plainText: "Bring the summit permit", fetchedAt: .now)
                .insert(db)
        }

        let cache = try MailCache(writer: queue)
        #expect(try await search(cache, "trail") == ["t1"])
        #expect(try await search(cache, "permit") == ["t1"])
        try await checkIntegrity(cache)
    }

    @Test func searchStaysWithinOneAccount() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [stored("m1", thread: "t1", subject: "Trail map")])
        try await seed(cache, [stored("m1", thread: "t1", account: "other", subject: "Trail map")], account: "other")
        let results = try await cache.read { tx in
            try tx.searchThreads(SearchQuery("trail"), accountID: acct, timeZone: .gmt, now: .now, limit: 10)
        }
        #expect(results.map(\.accountID) == [acct])
    }

    @Test func operatorsMatchOneMessageAtATime() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.replaceLabels([LabelRecord(accountID: acct, id: "Label_1", name: "Family/Trips", isSystem: false)], accountID: acct)
        }
        try await seed(cache, [
            stored("m1", thread: "t1", subject: "Dinner", sender: "Ann <ann@example.com>", labels: [SystemLabel.inbox, SystemLabel.unread]),
            stored("m2", thread: "t1", subject: "Re: Dinner", sender: "Ben <ben@example.com>", labels: [SystemLabel.sent], minutes: 5),
            stored("m3", thread: "t2", subject: "Movie", sender: "Ann <ann@example.com>", labels: ["Label_1"], minutes: 10),
        ])
        #expect(try await search(cache, "from:ann is:unread") == ["t1"])
        // Ben's message in t1 isn't unread, so the thread's union of labels doesn't count.
        #expect(try await search(cache, "from:ben is:unread").isEmpty)
        #expect(try await search(cache, "-from:ann") == ["t1"])
        #expect(try await search(cache, "from:ann is:read") == ["t2"])
        #expect(try await search(cache, "label:family-trips") == ["t2"])
        #expect(try await search(cache, "label:missing").isEmpty)
        #expect(try await search(cache, "subject:(dinner -re)") == ["t1"])
        #expect(try await search(cache, "{movie dinner} from:ann") == ["t2", "t1"])
    }

    @Test func spamAndTrashOnlyWhenTheQueryNamesThem() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [
            stored("m1", thread: "t1", subject: "Invoice", labels: [SystemLabel.trash]),
            stored("m2", thread: "t2", subject: "Invoice", labels: [SystemLabel.spam], minutes: 5),
        ])
        #expect(try await search(cache, "invoice").isEmpty)
        #expect(try await search(cache, "in:trash invoice") == ["t1"])
        #expect(try await search(cache, "in:anywhere invoice") == ["t2", "t1"])
    }

    @Test func datesUseTheGivenTimeZone() async throws {
        let cache = try MailCache.inMemory()
        // 2026-01-15 03:00 UTC is 22:00 on January 14 in New York.
        try await seed(cache, [stored("m1", thread: "t1", subject: "Trail", date: Date(timeIntervalSince1970: 1_768_446_000))])
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(try await search(cache, "after:2026/01/15", timeZone: .gmt) == ["t1"])
        #expect(try await search(cache, "after:2026/01/15", timeZone: newYork).isEmpty)
        #expect(try await search(cache, "before:2026/01/15", timeZone: newYork) == ["t1"])
    }

    @Test func onlyTheLastWordIsAPrefix() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [stored("m1", thread: "t1", subject: "Trail map")])
        #expect(try await search(cache, "map tra") == ["t1"])
        #expect(try await search(cache, "tra map").isEmpty)
        // A phrase, even one still being typed, matches whole words.
        #expect(try await search(cache, "\"trail ma").isEmpty)
    }

    @Test func gmailResultsJoinLocalMatchesOnce() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [
            stored("m1", thread: "t1", subject: "Trail map"),
            stored("m2", thread: "t2", subject: "Lunch", minutes: 5),
        ])
        #expect(try await search(cache, "trail", including: ["t1", "t2", "t9"]) == ["t2", "t1"])
        // A Gmail-only query lists only what Gmail returned.
        #expect(try await search(cache, "has:attachment", including: ["t1"]) == ["t1"])
        #expect(try await search(cache, "has:attachment").isEmpty)
    }

    @Test func resultsUpdateWhenMatchingMailArrives() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [stored("m1", thread: "t1", subject: "Trail map")])
        var results = cache.searchResults(SearchQuery("trail"), accountID: acct, timeZone: .gmt, now: .now, limit: 10)
            .makeAsyncIterator()
        #expect(try await results.next()?.map(\.id) == ["t1"])
        try await seed(cache, [stored("m2", thread: "t2", subject: "Trail run", minutes: 5)])
        var latest: [String]?
        while latest != ["t2", "t1"], let next = try await results.next() {
            latest = next.map(\.id)
        }
        #expect(latest == ["t2", "t1"])
    }
}

// MARK: Helpers

private func stored(
    _ id: String,
    thread: String,
    account: String = acct,
    subject: String,
    sender: String = "Sender <s@example.com>",
    labels: [String] = [SystemLabel.inbox],
    minutes: Double = 0,
    date: Date? = nil,
    historyID: Int64 = 100
) -> CacheTransaction.MessageUpdate {
    let record = MessageRecord(
        accountID: account, id: id, threadID: thread, historyID: historyID,
        date: date ?? Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60),
        snippet: "", sender: sender, recipients: "r@example.com",
        cc: nil, subject: subject, sizeEstimate: 1
    )
    return .init(record: record, labelIDs: labels)
}

private func seed(_ cache: MailCache, _ updates: [CacheTransaction.MessageUpdate], account: String = acct) async throws {
    try await cache.write { tx in
        try tx.rebuildThreads(tx.upsertMessages(updates), accountID: account)
    }
}

private func search(
    _ cache: MailCache,
    _ text: String,
    including: Set<String> = [],
    timeZone: TimeZone = .gmt
) async throws -> [String] {
    try await cache.read { tx in
        try tx.searchThreads(
            SearchQuery(text), including: including, accountID: acct, timeZone: timeZone,
            now: Date(timeIntervalSince1970: 1_900_000_000), limit: 50
        ).map(\.id)
    }
}

private func textWrites(_ cache: MailCache) async throws -> [String] {
    try await cache.writer.read { db in try String.fetchAll(db, sql: "SELECT messageID FROM textWrites") }
}

/// FTS5's own check that the index matches the content table.
private func checkIntegrity(_ cache: MailCache) async throws {
    try await cache.writer.write { db in
        try db.execute(sql: "INSERT INTO messageSearch(messageSearch, rank) VALUES('integrity-check', 1)")
    }
}
