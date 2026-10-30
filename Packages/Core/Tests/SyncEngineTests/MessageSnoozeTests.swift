import Foundation
import GmailAPI
import MailStore
import Testing
@testable import SyncEngine

@Suite struct MessageSnoozeTests {
    @Test func exactSnoozeAndUndoLeaveInboxSiblingsUntouched() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let (keeper, accounts) = try await messageKeeper(engine)
        try await seed(cache, [("m1", "t", [SystemLabel.inbox]), ("m2", "t", [SystemLabel.inbox])])
        let receipt = try #require(try await keeper.snooze(target: .messages(["m1"]), until: baseDate + 3600))
        #expect(try await labels(cache)["m1"] == [])
        #expect(try await labels(cache)["m2"] == [SystemLabel.inbox])
        #expect(try await messageHolds(cache).map(\.messageID) == ["m1"])
        #expect(try await cache.read { try $0.messageIDsInHeldThreads(accountID: account) } == ["m1"])
        await keeper.check()
        #expect(try await messageHolds(cache).count == 1)
        try await keeper.undoSnooze(receipt)
        #expect(try await labels(cache).values.allSatisfy { $0 == [SystemLabel.inbox] })
        #expect(try await messageHolds(cache).isEmpty)
        #expect(try await accounts.messageSnoozes(accountID: account).isEmpty)
        #expect(await gmail.changes.isEmpty)
    }

    @Test func independentWakeTimesAndResnoozeUndoStayMessageScoped() async throws {
        let (engine, cache, _, clock) = try await makeEngine()
        let (keeper, accounts) = try await messageKeeper(engine)
        try await seed(cache, [("m1", "t", [SystemLabel.inbox]), ("m2", "t", [SystemLabel.inbox])])
        _ = try await keeper.snooze(target: .messages(["m1"]), until: baseDate + 3600)
        _ = try await keeper.snooze(target: .messages(["m2"]), until: baseDate + 7200)
        let moved = try #require(try await keeper.snooze(target: .messages(["m1"]), until: baseDate + 10800))
        try await keeper.undoSnooze(moved)
        #expect(try await messageHolds(cache).map(\.wakeAt) == [baseDate + 3600, baseDate + 7200])
        clock.advance(3601)
        await keeper.check()
        #expect(try await labels(cache)["m1"] == [SystemLabel.inbox])
        #expect(try await labels(cache)["m2"] == [])
        #expect(try await messageHolds(cache).map(\.messageID) == ["m2"])
        #expect(try await accounts.messageSnoozes(accountID: account).map(\.messageID) == ["m2"])
        try await keeper.unsnooze(target: .messages(["m2"]))
        #expect(try await labels(cache)["m2"] == [SystemLabel.inbox])
        #expect(try await messageHolds(cache).isEmpty)
    }

    @Test func anOlderReceiptCannotCancelANewerSnoozeWithTheSameWakeTime() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let (keeper, accounts) = try await messageKeeper(engine)
        try await seed(cache, [("m1", "t", [SystemLabel.inbox])])
        let first = try #require(try await keeper.snooze(target: .messages(["m1"]), until: baseDate + 3600))
        _ = try await keeper.snooze(target: .messages(["m1"]), until: baseDate + 3600)
        let newest = try await messageHolds(cache)
        try await keeper.undoSnooze(first)
        #expect(try await messageHolds(cache) == newest)
        #expect(try await accounts.messageSnoozes(accountID: account) == newest)
        #expect(try await labels(cache)["m1"] == [])
    }

    @Test func switchingModesPreservesLegacySiblingsAndRestoresIndependentSchedulesOnUndo() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let (keeper, accounts) = try await messageKeeper(engine)
        try await seed(cache, [("m1", "t", [SystemLabel.inbox]), ("m2", "t", [SystemLabel.inbox])])
        let legacy = try #require(try await keeper.snooze(threadIDs: ["t"], until: baseDate + 3600))
        // A sibling outside the cache must also keep the legacy wake time.
        await gmail.setThread(try decode(GmailThread.self, #"{"id":"t","messages":[\#(try encodedMessage("m1", thread: "t", labels: [])),\#(try encodedMessage("m2", thread: "t", labels: [])),\#(try encodedMessage("m3", thread: "t", labels: []))]}"#))
        _ = try await keeper.snooze(target: .messages(["m1"]), until: baseDate + 7200)
        #expect(try await engine.snoozeHolds().isEmpty)
        let split = try await messageHolds(cache)
        #expect(Dictionary(uniqueKeysWithValues: split.map { ($0.messageID, $0.wakeAt) }) == ["m1": baseDate + 7200, "m2": baseDate + 3600, "m3": baseDate + 3600])
        #expect(try await accounts.snoozes(accountID: account).isEmpty)
        #expect(try await accounts.messageSnoozes(accountID: account).count == 3)
        // An old thread receipt cannot take back independently replaced intent.
        try await keeper.undoSnooze(legacy)
        #expect(try await labels(cache).values.allSatisfy(\.isEmpty))
        let whole = try #require(try await keeper.snooze(threadIDs: ["t"], until: baseDate + 10800))
        #expect(try await messageHolds(cache).isEmpty)
        #expect(try await accounts.messageSnoozes(accountID: account).isEmpty)
        try await keeper.undoSnooze(whole)
        #expect(try await engine.snoozeHolds().isEmpty)
        #expect(try await messageHolds(cache) == split)
        #expect(try await accounts.messageSnoozes(accountID: account) == split)
    }

    @Test func cacheResetRehydratesOnlyExactMessageAndDropsConfirmedMissingRecord() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let (keeper, accounts) = try await messageKeeper(engine)
        let records = ["m1", "gone"].map { MessageSnoozeRecord(accountID: account, messageID: $0, threadID: "t", wakeAt: baseDate + 3600, createdAt: baseDate) }
        try await accounts.applyMessageSnoozes(records, replacingThreads: [:], accountID: account)
        await gmail.add(try decode(GmailMessage.self, try encodedMessage("m1", thread: "t", labels: [])))
        await gmail.add(try decode(GmailMessage.self, try encodedMessage("sibling", thread: "t", labels: [SystemLabel.inbox])))
        await keeper.start()
        #expect(try await accounts.messageSnoozes(accountID: account).map(\.messageID) == ["m1"])
        #expect(try await messageHolds(cache).map(\.messageID) == ["m1"])
        #expect(try await cache.read { try $0.messages(threadID: "t", accountID: account).map(\.id) } == ["m1"])
        #expect(await gmail.metadataRequests.flatMap { $0 }.sorted() == ["gone", "m1"])
        #expect(await gmail.threadRequests.isEmpty)
        #expect(await gmail.changes.isEmpty)
    }

    @Test func unsnoozeDuringRehydrationDoesNotResurrectOldThreadIntent() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        let (keeper, accounts) = try await messageKeeper(engine)
        try await accounts.saveSnooze(.init(accountID: account, threadID: "t", wakeAt: baseDate + 3600, createdAt: baseDate))
        await gmail.setThread(try decode(GmailThread.self, #"{"id":"t","messages":[\#(try encodedMessage("m1", thread: "t", labels: []))]}"#))
        await gmail.holdNextThreads()
        let checking = Task { await keeper.check() }
        while await !gmail.isHoldingThreads { await Task.yield() }
        try await keeper.unsnooze(threadIDs: ["t"])
        await gmail.releaseThreads()
        await checking.value
        #expect(try await engine.snoozeHolds().isEmpty)
        #expect(try await accounts.snoozes(accountID: account).isEmpty)
    }

    @Test func interruptedModeConversionRollsForwardWithoutDroppingSiblingWakeIntent() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let (keeper, accounts) = try await messageKeeper(engine)
        try await seed(cache, [("m1", "t", []), ("m2", "t", [])])
        try await accounts.saveSnooze(.init(accountID: account, threadID: "t", wakeAt: baseDate + 3600, createdAt: baseDate))
        let split = [
            MessageSnoozeRecord(accountID: account, messageID: "m1", threadID: "t", wakeAt: baseDate + 7200, createdAt: baseDate),
            MessageSnoozeRecord(accountID: account, messageID: "m2", threadID: "t", wakeAt: baseDate + 3600, createdAt: baseDate)
        ]
        // The cache committed a split, but config still has the legacy record.
        try await cache.write { tx in for record in split { try tx.holdMessageSnooze(record) } }
        await keeper.check()
        #expect(try await accounts.snoozes(accountID: account).isEmpty)
        #expect(Set(try await accounts.messageSnoozes(accountID: account).map(\.messageID)) == ["m1", "m2"])
        #expect(Set(try await accounts.messageSnoozes(accountID: account).map(\.wakeAt)) == [baseDate + 3600, baseDate + 7200])
        // The reverse conversion committed only to cache before interruption.
        try await cache.write { tx in
            for record in split { try tx.releaseMessageSnooze(messageID: record.messageID, accountID: account) }
            try tx.holdSnooze(threadID: "t", until: baseDate + 10800, accountID: account)
        }
        await keeper.check()
        #expect(try await accounts.messageSnoozes(accountID: account).isEmpty)
        #expect(try await accounts.snoozes(accountID: account).map(\.wakeAt) == [baseDate + 10800])
        #expect(await gmail.metadataRequests.isEmpty)
        #expect(await gmail.threadRequests.isEmpty)
    }
}

private func messageKeeper(_ engine: SyncEngine) async throws -> (SnoozeKeeper, AccountStore) {
    let accounts = try AccountStore.inMemory()
    try await accounts.save(.init(id: account, email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: baseDate))
    return (SnoozeKeeper(engine: engine, accounts: accounts, schedulesChecks: false), accounts)
}

private func messageHolds(_ cache: MailCache) async throws -> [MessageSnoozeRecord] {
    try await cache.read { try $0.messageSnoozeHolds(accountID: account) }
}

private func labels(_ cache: MailCache) async throws -> [String: Set<String>] {
    try await cache.read { try $0.currentLabels(threadID: "t", accountID: account) }
}
