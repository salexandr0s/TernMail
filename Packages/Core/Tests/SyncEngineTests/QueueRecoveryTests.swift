import Foundation
import GmailAPI
import GRDB
@testable import MailStore
import Testing
@testable import SyncEngine

/// The change queue keeps going after a rejected sign-in, a write that
/// fails, or an error that doesn't pass.
@Suite struct QueueRecoveryTests {
    @Test func aRejectedSignInHoldsTheQueueUntilAPassReachesGmail() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t1"])
        await gmail.failNextChange(with: .unauthorized)
        await engine.sendDueActions()
        #expect(await engine.waitsForSignIn)
        let row = try #require(try await actions(cache).first)
        #expect(row.state == .queued)
        // No backoff: the change goes as soon as the account works again.
        #expect(row.notBefore == clock.now())
        #expect(try await summary(cache) == PendingChangeSummary(queued: 1, oldestError: "unauthorized"))

        try await engine.sync()
        #expect(await !engine.waitsForSignIn)
        await engine.sendDueActions()
        #expect(try await actions(cache).map(\.state) == [.sent])
        #expect(await gmail.changes == [archive("t1"), archive("t1")])
    }

    @Test func changesMadeWhileTheSignInIsRejectedGoTogetherAfterSignIn() async throws {
        let (engine, cache, gmail, _) = try await makeEngine(sendsAutomatically: true)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])], cursor: 100)
        await gmail.failNextChange(with: .unauthorized)
        try await engine.perform(.archive, threadIDs: ["t1"])
        try await waitUntil { await engine.waitsForSignIn }
        try await engine.perform(.archive, threadIDs: ["t2"])
        // The sender wakes for the new change and goes back to waiting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await gmail.changes == [archive("t1")])

        await engine.resumeAfterSignIn()
        try await waitUntil { await gmail.changes.count == 2 }
        #expect(await gmail.changes.last == archive("t1", "t2"))
        await engine.stop()
    }

    @Test func signingInEndsABackoffButNotAnUndoHold() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine(undoHolds: .uniform(30))
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t1"])
        clock.advance(31)
        await gmail.failNextChange(with: .transport(.notConnectedToInternet))
        await engine.sendDueActions()
        try await engine.perform(.archive, threadIDs: ["t2"])

        await engine.resumeAfterSignIn()
        await engine.sendDueActions()
        #expect(await gmail.changes == [archive("t1"), archive("t1")])
        #expect(try await actions(cache).map(\.state) == [.sent, .queued])
    }

    @Test func aFailedWriteOfTheOutcomeIsTriedAgain() async throws {
        let cache = try MailCache.inMemory()
        // The pause before the second try is when the disk comes back.
        let (engine, _, gmail, _) = try await makeEngine(cache: cache, sleep: { _ in try await allowSentRows(cache) })
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t1"])
        try await refuseSentRows(cache)
        await engine.sendDueActions()
        #expect(try await actions(cache).map(\.state) == [.sent])
        #expect(await gmail.changes == [archive("t1")])
    }

    @Test func aSendWhoseOutcomeWasLostGoesAgainAfterABackoff() async throws {
        let cache = try MailCache.inMemory()
        let (engine, _, gmail, clock) = try await makeEngine(cache: cache, sleep: { _ in })
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t1"])
        try await refuseSentRows(cache)
        await engine.sendDueActions()
        #expect(try await actions(cache).map(\.state) == [.sending])

        try await allowSentRows(cache)
        #expect(await engine.sendDueActions() == 0)
        let row = try #require(try await actions(cache).first)
        #expect(row.state == .queued)
        #expect(row.notBefore == clock.now().addingTimeInterval(2))
        clock.advance(2)
        #expect(await engine.sendDueActions() == 1)
        #expect(try await actions(cache).map(\.state) == [.sent])
        #expect(await gmail.changes == [archive("t1"), archive("t1")])
    }

    @Test func aSecondSendLeavesARowInFlightAlone() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t1"])
        await gmail.holdNextChange()
        let first = Task { await engine.sendDueActions() }
        while await !gmail.isHolding { await Task.yield() }

        #expect(await engine.sendDueActions() == 0)
        #expect(try await actions(cache).map(\.state) == [.sending])
        await gmail.release()
        #expect(await first.value == 1)
        #expect(try await actions(cache).map(\.state) == [.sent])
        #expect(await gmail.changes == [archive("t1")])
    }

    @Test func anErrorThatMayPassRefusesTheChangeOnItsLastTry() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        await gmail.setChangeErrors(["t1": .rateLimited])
        try await engine.perform(.archive, threadIDs: ["t1"])
        for _ in 1..<SyncEngine.retryLimit {
            await engine.sendDueActions()
            clock.advance(301)
        }
        #expect(try await actions(cache).map(\.state) == [.queued])
        await engine.sendDueActions()
        #expect(try await actions(cache).map(\.state) == [.failed])
        #expect(try await summary(cache) == PendingChangeSummary(failed: 1))
        #expect(await gmail.changes.count == SyncEngine.retryLimit)
    }

    @Test func aChangeThatCantReachGmailKeepsTrying() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t1"])
        for _ in 0...SyncEngine.retryLimit {
            await gmail.failNextChange(with: .transport(.notConnectedToInternet))
            await engine.sendDueActions()
            clock.advance(301)
        }
        #expect(try await actions(cache).map(\.state) == [.queued])
        #expect(await gmail.changes.count == SyncEngine.retryLimit + 1)
    }

    @Test func unreadableAnswersToADeliveredChangeCountAsSentOnTheThirdTry() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t1"])
        for _ in 1..<SyncEngine.unreadableAnswerLimit {
            await gmail.failNextChange(with: .decoding("Batch response has no boundary"))
            await engine.sendDueActions()
            clock.advance(301)
        }
        #expect(try await actions(cache).map(\.state) == [.queued])
        await gmail.failNextChange(with: .decoding("Batch response has no boundary"))
        await engine.sendDueActions()
        #expect(try await actions(cache).map(\.state) == [.sent])
    }
}

private func archive(_ threadIDs: String...) -> Change {
    Change("modifyThreads", threadIDs, remove: [SystemLabel.inbox])
}

/// Every row, refused ones included.
private func actions(_ cache: MailCache) async throws -> [PendingAction] {
    try await cache.read { tx in try tx.allActions(accountID: account) }
}

private func summary(_ cache: MailCache) async throws -> PendingChangeSummary? {
    for try await summary in cache.pendingChangeSummary(accountID: account) { return summary }
    return nil
}

/// Makes every write that marks a change sent fail, as a full disk would.
private func refuseSentRows(_ cache: MailCache) async throws {
    try await cache.write { tx in
        try tx.db.execute(sql: """
            CREATE TEMP TRIGGER refuseSentRow BEFORE UPDATE OF state ON main.pendingAction
            WHEN NEW.state = '\(PendingAction.State.sent.rawValue)'
            BEGIN SELECT RAISE(ABORT, 'disk unavailable'); END
            """)
    }
}

private func allowSentRows(_ cache: MailCache) async throws {
    try await cache.write { tx in try tx.db.execute(sql: "DROP TRIGGER IF EXISTS temp.refuseSentRow") }
}

private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("The condition didn't hold within 2 seconds.")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
