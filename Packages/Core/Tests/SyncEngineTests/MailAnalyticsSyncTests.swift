import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct MailAnalyticsSyncTests {
    @Test func pagesResumeAndKeepAnalyticsSeparateFromTheMessageCache() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try analyticsMessage("first"))
        await gmail.setRecentPages([try analyticsPage(ids: ["first"], next: "older")])
        let first = try await engine.loadAnalyticsHistoryPage()
        #expect(first.nextPageToken == "older")
        #expect(first.indexedMessageCount == 1)
        #expect(!first.isComplete)
        await engine.stop()
        let (resumed, _, nextGmail, _) = try await makeEngine(cache: cache)
        await nextGmail.add(try analyticsMessage("second"))
        await nextGmail.setRecentPages([try analyticsPage(ids: ["second"], next: nil)])
        let complete = try await resumed.loadAnalyticsHistoryPage()
        #expect(complete.isComplete)
        #expect(complete.indexedMessageCount == 2)
        #expect(complete.historyLoadedAt != nil)
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: account) }.isEmpty)
        #expect(await nextGmail.changes.isEmpty)
        #expect(await nextGmail.fullThreadRequests.isEmpty)
        await resumed.stop()
    }

    @Test func failedMetadataDoesNotAdvanceOrPartiallyCommitAPage() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try analyticsMessage("first"))
        await gmail.add(try analyticsMessage("second"))
        await gmail.setMetadataErrors(["second": .rateLimited])
        await gmail.setRecentPages([try analyticsPage(ids: ["first", "second"], next: "older")])
        await #expect(throws: GmailError.rateLimited) { try await engine.loadAnalyticsHistoryPage() }
        let state = try await cache.read { try $0.analyticsCoverage(accountID: account) }
        #expect(state.nextPageToken == nil)
        #expect(!state.isComplete)
        #expect(state.indexedMessageCount == 0)
        #expect(state.lastError != nil)
        await engine.stop()
    }

    @Test func stopWhileFetchingPreventsLateWritesAndCompletedCoverage() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try analyticsMessage("first"))
        await gmail.setRecentPages([try analyticsPage(ids: ["first"], next: nil)])
        let (entered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await gmail.holdNextMetadata {
            signal.yield(())
            signal.finish()
        }
        let task = Task { try await engine.loadAnalyticsHistoryPage() }
        for await _ in entered { break }
        try #require(await gmail.isHoldingMetadata)
        await engine.stop()
        await gmail.releaseMetadata()
        await #expect(throws: CancellationError.self) { try await task.value }
        let state = try await cache.read { try $0.analyticsCoverage(accountID: account) }
        #expect(state.indexedMessageCount == 0)
        #expect(!state.isComplete)
    }
}

private func analyticsMessage(_ id: String) throws -> GmailMessage {
    try decode(GmailMessage.self, #"""
        {"id":"\#(id)","threadId":"t-\#(id)","historyId":"200","internalDate":"1700000000000","labelIds":["INBOX"],
         "payload":{"headers":[{"name":"From","value":"Alex <alex@example.test>"},{"name":"To","value":"me@example.test"}]}}
        """#)
}

private func analyticsPage(ids: [String], next: String?) throws -> MessageListPage {
    var json: [String: Any] = ["messages": ids.map { ["id": $0, "threadId": "t-\($0)"] }]
    if let next { json["nextPageToken"] = next }
    return try JSONDecoder().decode(MessageListPage.self, from: JSONSerialization.data(withJSONObject: json))
}
