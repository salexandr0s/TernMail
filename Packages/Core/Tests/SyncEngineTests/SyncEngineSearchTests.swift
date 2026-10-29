import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct SyncEngineSearchTests {
    @Test func gmailSearchStoresAndHoldsWhatTheCacheLacks() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        await gmail.setThreadPages("trail", [["t1", "t2", "t1", "t9"]])
        await gmail.setThread(try thread("t2", [("m2", ["Label_1"]), ("m3", ["Label_1"])]))
        // Deleted while the search was out.
        let tombstones = await engine.deletedMessageIDs
        tombstones.withLock { _ = $0.insert("m3") }

        let page = try await engine.searchGmail(SearchQuery("trail"), timeZone: .gmt)

        // t9 was gone by the time Tern asked for it.
        #expect(page == GmailResultPage(threadIDs: ["t1", "t2"], nextPageToken: nil))
        #expect(await gmail.threadRequests == [["t2", "t9"]])
        #expect(await gmail.threadRequestHeaders == SyncEngine.metadataHeaders)
        let (messages, held) = try await cache.read { tx in
            (try tx.cachedMessageIDs(accountID: account), try tx.heldThreadIDs(accountID: account))
        }
        #expect(messages == ["m1", "m2"])
        #expect(held == ["t1", "t2"])
    }

    @Test func aResultPrunedDuringTheFetchIsFetchedAgain() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        // t1 is cached under an expired search hold, past the 30 days full sync keeps.
        try await seed(cache, [("m1", "t1", [])], cursor: 200)
        try await cache.write { tx in try tx.holdSearchResults(["t1"], until: baseDate + 60, accountID: account) }
        clock.advance(31 * 24 * 60 * 60)
        await gmail.setThreadPages("trail", [["t1", "t2"]])
        await gmail.setThread(try thread("t1", [("m1", [])]))
        await gmail.setThread(try thread("t2", [("m2", [])]))

        await gmail.holdNextThreads()
        let searching = Task { try await engine.searchGmail(SearchQuery("trail"), timeZone: .gmt) }
        while await !gmail.isHoldingThreads { await Task.yield() }
        // The pass releases t1's hold and drops its messages while t2 is fetched.
        try await engine.sync()
        await gmail.releaseThreads()
        let page = try await searching.value

        #expect(page.threadIDs == ["t1", "t2"])
        #expect(await gmail.threadRequests == [["t2"], ["t1"]])
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1", "m2"])
    }

    @Test func requestsFollowTheQueryAndTheLabel() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        await gmail.setThreadPages("in:trash after:1768453200", [["t1"], ["t2"]])

        let first = try await engine.searchGmail(SearchQuery("in:trash after:2026/01/15"), timeZone: newYork)
        _ = try await engine.searchGmail(SearchQuery("in:trash after:2026/01/15"), timeZone: newYork, pageToken: first.nextPageToken)
        _ = try await engine.loadOlder(labelID: SystemLabel.trash)
        _ = try await engine.loadOlder(labelID: "Label_1", pageToken: "4")
        _ = try await engine.loadOlder(labelID: SystemLabel.sent, before: Date(timeIntervalSince1970: 1_768_453_200.5))

        #expect(first.nextPageToken == "1")
        #expect(await gmail.threadSearches == [
            ThreadSearch(query: "in:trash after:1768453200", labelIDs: [], includeSpamTrash: true, pageToken: nil),
            ThreadSearch(query: "in:trash after:1768453200", labelIDs: [], includeSpamTrash: true, pageToken: "1"),
            ThreadSearch(query: nil, labelIDs: [SystemLabel.trash], includeSpamTrash: true, pageToken: nil),
            ThreadSearch(query: nil, labelIDs: ["Label_1"], includeSpamTrash: false, pageToken: "4"),
            ThreadSearch(query: "before:1768453201", labelIDs: [SystemLabel.sent], includeSpamTrash: false, pageToken: nil),
        ])
    }

    @Test func aCancelledSearchStoresNothing() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.setThreadPages("trail", [["t2"]])
        await gmail.setThread(try thread("t2", [("m2", [])]))
        await gmail.holdNextThreadList()
        let older = Task { try await engine.searchGmail(SearchQuery("trail"), timeZone: .gmt) }
        while await !gmail.isHoldingThreadList { await Task.yield() }
        // A newer query cancels the older one.
        older.cancel()
        await gmail.releaseThreadList()

        await #expect(throws: CancellationError.self) { try await older.value }
        #expect(await gmail.threadRequests.isEmpty)
        #expect(try await cache.read { tx in try tx.heldThreadIDs(accountID: account) }.isEmpty)
    }

    @Test func fullSyncRefetchesHeldConversations() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", []), ("m2", "t1", [])])
        try await cache.write { tx in
            try tx.holdSearchResults(["t1"], until: baseDate + CacheHolds.searchLifetime, accountID: account)
        }
        // Gmail relabeled m1 and deleted m2.
        await gmail.add(try decode(GmailMessage.self, try encodedMessage("m1", thread: "t1", labels: ["Label_1"], historyID: 150)))

        try await engine.sync()

        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1"])
        var labeled = cache.threads(accountID: account, labelID: "Label_1", limit: 10).makeAsyncIterator()
        #expect(try await labeled.next()?.map(\.id) == ["t1"])
        #expect(await gmail.metadataRequests.flatMap { $0 }.sorted() == ["m1", "m2"])
    }

    @Test func expiredHoldsAreReleasedAfterAPassExceptForVisibleConversations() async throws {
        let (engine, cache, _, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", []), ("m2", "t2", [])], cursor: 200)
        try await cache.write { tx in
            try tx.holdSearchResults(["t1", "t2"], until: baseDate + 60, accountID: account)
        }
        // Past the hold and past the 30 days full sync keeps.
        clock.advance(31 * 24 * 60 * 60)
        engine.setVisibleThreads(["t2"])

        try await engine.sync()

        let (messages, held) = try await cache.read { tx in
            (try tx.cachedMessageIDs(accountID: account), try tx.heldThreadIDs(accountID: account))
        }
        #expect(messages == ["m2"])
        #expect(held == ["t2"])
    }
}

/// A metadata-format conversation.
private func thread(_ id: String, _ messages: [(id: String, labels: [String])]) throws -> GmailThread {
    let encoded = try messages.map { try encodedMessage($0.id, thread: id, labels: $0.labels, historyID: 150) }
    return try decode(GmailThread.self, #"{"id": "\#(id)", "messages": [\#(encoded.joined(separator: ","))]}"#)
}
