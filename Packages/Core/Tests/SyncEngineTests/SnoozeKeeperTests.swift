import Foundation
import GmailAPI
import MailStore
import Testing
@testable import SyncEngine

private let hour: TimeInterval = 60 * 60

@Suite struct SnoozeKeeperTests {
    @Test func undoMatchesFractionalWakeTimeUsingStoredPrecision() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let (keeper, accounts) = try await makeKeeper(engine)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        let wakeAt = baseDate + hour + 0.123456
        let receipt = try #require(try await keeper.snooze(threadIDs: ["t1"], until: wakeAt))
        let stored = try #require(try await holds(cache)["t1"])
        #expect(stored != wakeAt)

        try await keeper.undoSnooze(receipt)
        #expect(try await listed(cache, SystemLabel.inbox) == ["t1"])
        #expect(try await rows(cache).isEmpty)
        #expect(try await holds(cache).isEmpty)
        #expect(try await accounts.snoozes(accountID: account).isEmpty)
    }

    @Test func snoozingArchivesAndHoldsTogetherAndUndoTakesItAllBack() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        let (keeper, accounts) = try await makeKeeper(engine)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])

        let receipt = try #require(try await keeper.snooze(threadIDs: ["t1"], until: baseDate + hour))
        #expect(try await listed(cache, SystemLabel.inbox).isEmpty)
        #expect(try await holds(cache) == ["t1": baseDate + hour])
        #expect(try await accounts.snoozes(accountID: account).map(\.threadID) == ["t1"])
        // The archive is still queued, which doesn't end the snooze.
        await keeper.check()
        #expect(try await holds(cache) == ["t1": baseDate + hour])

        try await keeper.undoSnooze(receipt)
        #expect(try await listed(cache, SystemLabel.inbox) == ["t1"])
        #expect(try await holds(cache).isEmpty)
        #expect(try await accounts.snoozes(accountID: account).isEmpty)
        clock.advance(3)
        await engine.sendDueActions()
        #expect(await gmail.changes.isEmpty)
    }

    @Test func undoingASnoozeAgainPutsBackTheEarlierSnooze() async throws {
        let (engine, cache, _, clock) = try await makeEngine()
        let (keeper, accounts) = try await makeKeeper(engine)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])])
        _ = try await keeper.snooze(threadIDs: ["t1"], until: baseDate + hour)
        clock.advance(3)
        await engine.sendDueActions()

        let again = try #require(try await keeper.snooze(threadIDs: ["t1"], until: baseDate + 2 * hour))
        try await keeper.undoSnooze(again)
        #expect(try await holds(cache) == ["t1": baseDate + hour])
        #expect(try await accounts.snoozes(accountID: account).map(\.wakeAt) == [baseDate + hour])
        #expect(try await listed(cache, SystemLabel.inbox) == ["t2"])

        // Undoing a snooze after a newer one leaves the newer one alone.
        let first = try #require(try await keeper.snooze(threadIDs: ["t2"], until: baseDate + hour))
        _ = try await keeper.snooze(threadIDs: ["t2"], until: baseDate + 3 * hour)
        try await keeper.undoSnooze(first)
        #expect(try await holds(cache) == ["t1": baseDate + hour, "t2": baseDate + 3 * hour])
        #expect(try await accounts.snoozes(accountID: account).map(\.threadID) == ["t1", "t2"])
        #expect(try await listed(cache, SystemLabel.inbox).isEmpty)

        clock.advance(hour)
        await keeper.check()
        #expect(try await listed(cache, SystemLabel.inbox) == ["t1"])
    }

    @Test func aSnoozeMovedDuringACheckIsNeitherWokenNorHeldAtItsOldTime() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        let (keeper, accounts) = try await makeKeeper(engine)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        _ = try await keeper.snooze(threadIDs: ["t1"], until: baseDate + hour)
        // A cache reset dropped t2's messages, so the check fetches them.
        try await cache.write { tx in try tx.holdSnooze(threadID: "t2", until: baseDate + 2 * hour, accountID: account) }
        await gmail.setThread(try thread("t2", [("m2", [])]))
        clock.advance(hour)

        await gmail.holdNextThreads()
        let checking = Task { await keeper.check() }
        while await !gmail.isHoldingThreads { await Task.yield() }
        // t1 is due as the check read it, and t2's fetch read the old time.
        _ = try await keeper.snooze(threadIDs: ["t1", "t2"], until: baseDate + 5 * hour)
        await gmail.releaseThreads()
        await checking.value

        #expect(try await holds(cache) == ["t1": baseDate + 5 * hour, "t2": baseDate + 5 * hour])
        #expect(try await accounts.snoozes(accountID: account).map(\.wakeAt) == [baseDate + 5 * hour, baseDate + 5 * hour])
        #expect(try await listed(cache, SystemLabel.inbox).isEmpty)
    }

    @Test func wakingBringsTheConversationBackSortedByItsWakeTime() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        let (keeper, accounts) = try await makeKeeper(engine)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])])
        _ = try await keeper.snooze(threadIDs: ["t1"], until: baseDate + hour)
        clock.advance(3)
        await engine.sendDueActions()

        clock.advance(hour)
        await keeper.check()
        #expect(try await listed(cache, SystemLabel.inbox) == ["t1", "t2"])
        #expect(try await inboxOrder(cache) == ["t1", "t2"])
        #expect(try await holds(cache).isEmpty)
        #expect(try await accounts.snoozes(accountID: account).isEmpty)

        // A crash before the record was deleted wakes it again, which changes nothing.
        try await accounts.saveSnooze(SnoozeRecord(accountID: account, threadID: "t1", wakeAt: baseDate + hour, createdAt: baseDate))
        await gmail.setThread(try thread("t1", [("m1", [])]))
        await keeper.check()
        while await engine.sendDueActions() > 0 {}
        #expect(await gmail.changes == [
            Change("modifyThreads", ["t1"], remove: [SystemLabel.inbox]),
            Change("batchModify", ["m1"], add: [SystemLabel.inbox]),
            Change("batchModify", ["m1"], add: [SystemLabel.inbox]),
        ])
        #expect(try await holds(cache).isEmpty)
        #expect(try await accounts.snoozes(accountID: account).isEmpty)
    }

    @Test func aConversationTrashedWhileSnoozedStaysInTrash() async throws {
        let (engine, cache, _, clock) = try await makeEngine()
        let (keeper, accounts) = try await makeKeeper(engine)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        _ = try await keeper.snooze(threadIDs: ["t1"], until: baseDate + hour)
        _ = try await engine.perform(.trash, threadIDs: ["t1"])

        clock.advance(hour)
        await keeper.check()
        #expect(try await listed(cache, SystemLabel.trash) == ["t1"])
        #expect(try await listed(cache, SystemLabel.inbox).isEmpty)
        #expect(try await rows(cache).map(\.kind) == [.modifyThreads, .trashThreads])
        #expect(try await holds(cache).isEmpty)
        #expect(try await accounts.snoozes(accountID: account).isEmpty)
    }

    @Test func newMailInTheInboxEndsTheSnoozeEarly() async throws {
        let (engine, cache, _, clock) = try await makeEngine()
        let (keeper, accounts) = try await makeKeeper(engine)
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        _ = try await keeper.snooze(threadIDs: ["t1"], until: baseDate + 24 * hour)
        clock.advance(3)
        await engine.sendDueActions()
        // The next pass brings Gmail's archived copy and a reply in the Inbox.
        try await cache.write { tx in try tx.dropSentActions(sentBefore: .distantFuture, accountID: account) }
        try await seed(cache, [("m1", "t1", []), ("m2", "t1", [SystemLabel.inbox])])

        await keeper.check()
        #expect(try await holds(cache).isEmpty)
        #expect(try await accounts.snoozes(accountID: account).isEmpty)
        #expect(try await rows(cache).isEmpty)
        #expect(try await first(cache.wokenThreadIDs(accountID: account)).isEmpty)
    }

    @Test func launchRecordsHoldsAndHoldsAgainWhatACacheResetDropped() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let (keeper, accounts) = try await makeKeeper(engine)
        // A hold whose record a crash lost.
        try await seed(cache, [("m1", "t1", [])])
        try await cache.write { tx in try tx.holdSnooze(threadID: "t1", until: baseDate + hour, accountID: account) }
        // Records whose conversations a cache reset dropped: one Gmail still has, one it deleted.
        for threadID in ["t2", "t3"] {
            try await accounts.saveSnooze(SnoozeRecord(accountID: account, threadID: threadID, wakeAt: baseDate + 2 * hour, createdAt: baseDate))
        }
        await gmail.setThread(try thread("t2", [("m2", [])]))

        await keeper.start()
        #expect(try await accounts.snoozes(accountID: account).map(\.threadID) == ["t1", "t2"])
        #expect(try await holds(cache) == ["t1": baseDate + hour, "t2": baseDate + 2 * hour])
        #expect(try await first(cache.snoozedThreads(accountID: account)).map(\.id) == ["t1", "t2"])
    }
}

// MARK: Helpers

private func makeKeeper(_ engine: SyncEngine) async throws -> (SnoozeKeeper, AccountStore) {
    let accounts = try AccountStore.inMemory()
    try await accounts.save(AccountRecord(id: account, email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: baseDate))
    return (SnoozeKeeper(engine: engine, accounts: accounts, schedulesChecks: false), accounts)
}

private func thread(_ id: String, _ messages: [(id: String, labels: [String])]) throws -> GmailThread {
    let encoded = try messages.map { try encodedMessage($0.id, thread: id, labels: $0.labels, historyID: 150) }
    return try decode(GmailThread.self, #"{"id": "\#(id)", "messages": [\#(encoded.joined(separator: ","))]}"#)
}

private func holds(_ cache: MailCache) async throws -> [String: Date] {
    try await cache.read { tx in try tx.snoozeHolds(accountID: account) }
}

private func rows(_ cache: MailCache) async throws -> [PendingAction] {
    try await cache.read { tx in try tx.pendingActions(accountID: account) }
}

/// Conversations listed under a label, sorted by ID.
private func listed(_ cache: MailCache, _ labelID: String) async throws -> [String] {
    try await first(cache.threads(accountID: account, labelID: labelID, limit: 100)).map(\.id).sorted()
}

/// The Inbox as the thread list orders it.
private func inboxOrder(_ cache: MailCache) async throws -> [String] {
    try await first(cache.threads(accountID: account, labelID: SystemLabel.inbox, limit: 100)).map(\.id)
}

private func first<T>(_ stream: AsyncThrowingStream<T, any Error>) async throws -> T {
    for try await value in stream { return value }
    throw CancellationError()
}
