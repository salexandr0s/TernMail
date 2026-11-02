import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct SyncRequestTests {
    @Test func aCancelledCallerDoesNotStartASyncPass() async throws {
        let (engine, cache, gmail, _) = try await makeRequestEngine()
        try await seed(cache, [], cursor: 100)
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.sync()
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(await gmail.historyCalls == 0)
        await engine.stop()
    }

    @Test func cancellingOneCallerDoesNotCancelTheSharedPass() async throws {
        let (engine, cache, gmail, _) = try await makeRequestEngine()
        try await seed(cache, [], cursor: 100)
        await gmail.holdHistory(call: 1)
        let caller = Task { try await engine.sync() }
        while await !gmail.isHoldingHistory { await Task.yield() }
        caller.cancel()
        let shared = try #require(await engine.pass)
        await gmail.releaseHistory()
        _ = try await shared.value
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(await gmail.historyCalls == 1)
        await engine.stop()
    }

    @Test func labelInvalidationDuringAFullSyncSurvivesItsCompletion() async throws {
        let (engine, _, gmail, _) = try await makeRequestEngine()
        await gmail.add(try decode(GmailMessage.self, try encodedMessage("m1", thread: "t1")), inInbox: true)
        await gmail.holdNextMetadata()
        let running = Task { try await engine.sync() }
        while await !gmail.isHoldingMetadata { await Task.yield() }
        await engine.requestLabelRefresh()
        await gmail.releaseMetadata()
        try await running.value

        try await engine.sync()
        #expect(await gmail.labelListRequests == 2)
        await engine.stop()
    }

    @Test func requestsDuringAPassRunExactlyOneMorePass() async throws {
        let (engine, cache, gmail, sleeps) = try await makeRequestEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, SystemLabel.unread])], cursor: 100)
        await gmail.queueHistory(try decode(HistoryPage.self, """
            {"historyId": "110", "history": [{"id": "110", "messagesAdded": [{"message": {"id": "m2", "threadId": "t2"}}]}]}
            """))
        await gmail.queueHistory(try readPage(historyID: 120))
        // The running pass waits on the new message's metadata.
        await gmail.holdNextMetadata()
        let running = Task { try await engine.sync() }
        while await !gmail.isHoldingMetadata { await Task.yield() }
        for _ in 0..<3 { await engine.requestSync(reason: .manual) }
        await gmail.releaseMetadata()
        try await running.value
        await requestedPasses(engine)

        // The page that came after the running pass's history was applied, by one pass.
        #expect(try await cache.syncState(accountID: account)?.historyID == 120)
        #expect(await sleeps.durations.isEmpty)
        #expect(await events(engine) == [.syncStarted, .syncFinished(baseDate)])
    }

    @Test func aSignalledPassThatFindsNoHistoryTriesAgainAfterOneAndThreeSeconds() async throws {
        let (engine, cache, gmail, sleeps) = try await makeRequestEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, SystemLabel.unread])], cursor: 100)
        // The signal comes before history shows the change.
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId": "100"}"#))
        await gmail.queueHistory(try readPage(historyID: 120))
        await engine.requestSync(reason: .inboxSignal)
        await requestedPasses(engine)
        #expect(try await cache.read { tx in try tx.thread(id: "t1", accountID: account)?.isUnread } == false)
        #expect(await sleeps.durations == [.seconds(1)])

        // When history never shows anything, the passes stop after the second retry.
        await engine.requestSync(reason: .inboxSignal)
        await requestedPasses(engine)
        #expect(await sleeps.durations == [.seconds(1), .seconds(1), .seconds(3)])

        // A manual request takes one pass, found or not.
        await engine.requestSync(reason: .manual)
        await requestedPasses(engine)
        #expect(await sleeps.durations == [.seconds(1), .seconds(1), .seconds(3)])
        #expect(await events(engine).filter { $0 == .syncStarted }.count == 6)
    }
}

private func makeRequestEngine() async throws -> (SyncEngine, MailCache, FakeGmail, SleepLog) {
    let cache = try MailCache.inMemory()
    let gmail = FakeGmail()
    let sleeps = SleepLog()
    let engine = SyncEngine(
        accountID: account,
        sender: EmailAddress(name: "Me", address: "me@example.com"),
        outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "TernTests-\(UUID().uuidString)", directoryHint: .isDirectory),
        gmail: gmail,
        cache: cache,
        sendsAutomatically: false,
        sleep: { await sleeps.record($0) },
        now: TestClock().now
    )
    return (engine, cache, gmail, sleeps)
}

/// A history page in which m1 was read.
private func readPage(historyID: Int) throws -> HistoryPage {
    try decode(HistoryPage.self, """
        {"historyId": "\(historyID)", "history": [
          {"id": "\(historyID)", "labelsRemoved": [{"message": {"id": "m1", "threadId": "t1"}, "labelIds": ["UNREAD"]}]}
        ]}
        """)
}

private func requestedPasses(_ engine: SyncEngine) async {
    if let passes = await engine.requestedPasses { await passes.value }
}

private func events(_ engine: SyncEngine) async -> [SyncEvent] {
    await engine.stop()
    var events: [SyncEvent] = []
    for await event in engine.events { events.append(event) }
    return events
}
