import Foundation
import MailStore
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct MessagePrefetchTests {
    @Test func lookaheadUsesDisplayedOrderAndKeepsAccountIdentity() {
        let rows = (0..<10).map { MailListRowID(accountID: "a", threadID: "t\($0)") }
        let nearby = MessagePrefetchPlan.candidates(rows: rows, selected: [rows[4]])
        #expect(nearby == [rows[5], rows[6], rows[3], rows[7]].map(\.threadKey))
        #expect(MessagePrefetchPlan.candidates(rows: rows, selected: []) == Array(rows.prefix(4)).map(\.threadKey))

        let otherAccount = MailListRowID(accountID: "b", threadID: rows[0].threadID)
        let sibling = MailListRowID(accountID: "a", threadID: rows[0].threadID, messageID: "sibling")
        #expect(MessagePrefetchPlan.candidates(rows: [rows[0], sibling, otherAccount, rows[1]], selected: [rows[0]])
            == [otherAccount.threadKey, rows[1].threadKey])
        #expect(MessagePrefetchPlan.candidates(rows: [rows[0]], selected: [rows[0]]).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func rapidSelectionsRestartTheDeadlineEvenWhenNeighborsAreUnchanged() async throws {
        try await withFixtures(count: 1) { fixtures, controller, gate in
            let fixture = fixtures[0], mailbox = fixture.mailbox
            let first = MessagePrefetchPlan(keys: [fixture.key(1)], accounts: mailbox.accounts.map(ObjectIdentifier.init),
                selected: [MailListRowID(accountID: "ui-audit", threadID: "selected-a")])
            let second = MessagePrefetchPlan(keys: first.keys, accounts: first.accounts,
                selected: [MailListRowID(accountID: "ui-audit", threadID: "selected-b")])
            // SwiftUI's onChange must see a new selection even if its neighbor
            // list and account instances happen to be identical.
            #expect(first != second)
            let before = ContinuousClock.now
            controller.update(keys: first.keys, accounts: mailbox.accounts, mailbox: mailbox)
            let after = ContinuousClock.now
            try await waitUntil { await gate.deadlines.count == 1 }
            let deadline = try #require(await gate.deadlines.first)
            #expect(deadline >= before.advanced(by: .milliseconds(90)))
            #expect(deadline <= after.advanced(by: .milliseconds(90)))

            controller.update(keys: second.keys, accounts: mailbox.accounts, mailbox: mailbox)
            try await waitUntil { await gate.deadlines.count == 2 }
            #expect(await gate.cancellations == 1)
            let latest = controller.update(keys: [fixture.key(5)], accounts: mailbox.accounts, mailbox: mailbox)
            try await waitUntil { await gate.deadlines.count == 3 }
            #expect(await gate.cancellations == 2)
            #expect(await fixture.transport.statistics().requestCounts["body", default: 0] == 0)

            await gate.releaseLatest()
            await latest.value
            try await waitUntil { try await hasPrepared(5, in: fixture) }
            #expect(try await body(1, in: fixture) == nil)
            #expect(try await body(3, in: fixture) == nil)
            #expect(await fixture.transport.statistics().requestCounts["body"] == 1)
            try await expectNoReadingSideEffects(in: fixture)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func hidingBeforeTheDeadlineCancelsBothHydrationAndPreparation() async throws {
        try await withFixtures(count: 1) { fixtures, controller, gate in
            let fixture = fixtures[0], mailbox = fixture.mailbox
            controller.update(keys: [fixture.key(1)], accounts: mailbox.accounts, mailbox: mailbox)
            try await waitUntil { await gate.deadlines.count == 1 }
            await controller.stop().value
            #expect(await gate.cancellations == 1)
            await gate.releaseLatest()
            #expect(await fixture.transport.statistics().requestCounts["body", default: 0] == 0)
            #expect(try await body(1, in: fixture) == nil)

            // Resuming is a positive control: stopping did not disable future
            // plans, and work begins only after the next selection settles.
            let resumed = controller.update(keys: [fixture.key(3)], accounts: mailbox.accounts, mailbox: mailbox)
            try await waitUntil { await gate.deadlines.count == 2 }
            #expect(await fixture.transport.statistics().requestCounts["body", default: 0] == 0)
            await gate.releaseLatest()
            await resumed.value
            try await waitUntil { try await hasPrepared(3, in: fixture) }
            #expect(try await body(1, in: fixture) == nil)
            try await expectNoReadingSideEffects(in: fixture)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func supersedingCleanupStillCancelsTheSubmittedOwnerWithTheSameAccountID() async throws {
        try await withFixtures(count: 3) { fixtures, controller, gate in
            let old = fixtures[0], intermediate = fixtures[1], replacement = fixtures[2]
            #expect(old.mailbox.accounts[0].account.id == replacement.mailbox.accounts[0].account.id)
            #expect(old.mailbox.accounts[0] !== replacement.mailbox.accounts[0])
            await old.transport.configure(.delayed)
            let submitted = controller.update(keys: [old.key(1)], accounts: old.mailbox.accounts, mailbox: old.mailbox)
            try await waitUntil { await gate.deadlines.count == 1 }
            await gate.releaseLatest()
            // Submission must finish even while body retrieval remains held.
            await submitted.value
            try await waitUntil { await old.transport.statistics().requestCounts["body", default: 0] == 1 }
            controller.update(keys: [intermediate.key(3)], accounts: intermediate.mailbox.accounts, mailbox: intermediate.mailbox)
            let latest = controller.update(keys: [replacement.key(5)], accounts: replacement.mailbox.accounts, mailbox: replacement.mailbox)
            try await waitUntil { await gate.deadlines.count == 2 }
            // No engine.stop() or runtime replacement helper has run: cleanup
            // belongs to the controller, including its canceled intermediate task.
            try await waitUntil { await old.transport.statistics().cancelledRequests == 1 }
            #expect(await intermediate.transport.statistics().requestCounts["body", default: 0] == 0)
            #expect(await replacement.transport.statistics().requestCounts["body", default: 0] == 0)
            await gate.releaseLatest()
            await latest.value
            try await waitUntil { try await hasPrepared(5, in: replacement) }
            #expect(try await body(1, in: old) == nil)
            #expect(try await body(3, in: intermediate) == nil)
            #expect(await replacement.transport.statistics().requestCounts["body"] == 1)
            for fixture in fixtures { try await expectNoReadingSideEffects(in: fixture) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func foregroundOpenDoesNotWaitForTheNeighborDeadline() async throws {
        try await withFixtures(count: 1) { fixtures, controller, gate in
            let fixture = fixtures[0], mailbox = fixture.mailbox
            let pending = controller.update(keys: [fixture.key(3)], accounts: mailbox.accounts, mailbox: mailbox)
            try await waitUntil { await gate.deadlines.count == 1 }
            try await mailbox.accounts[0].engine.openThread(fixture.key(1).threadID, markRead: false)
            #expect(try await body(1, in: fixture) != nil)
            #expect(try await body(3, in: fixture) == nil)
            #expect(await fixture.transport.statistics().requestCounts["body"] == 1)
            await gate.releaseLatest()
            await pending.value
            try await waitUntil { try await hasPrepared(3, in: fixture) }
            #expect(await fixture.transport.statistics().requestCounts["body"] == 2)
            try await expectNoReadingSideEffects(in: fixture, opened: fixture.key(1).threadID)
        }
    }

    @MainActor private struct Fixture {
        let mailbox: MailboxModel
        let transport: PerformanceAuditTransport
        let defaults: UserDefaults
        let suite: String

        func key(_ index: Int) -> ThreadKey { ThreadKey(accountID: "ui-audit", threadID: "performance-thread-\(index)") }

        func stop() async {
            await mailbox.stop()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func withFixtures(count: Int,
        run: @MainActor ([Fixture], MessagePrefetchController, PrefetchSettleGate) async throws -> Void) async throws {
        var fixtures: [Fixture] = []
        let gate = PrefetchSettleGate()
        let controller = MessagePrefetchController(delay: .milliseconds(90), waitUntil: { try await gate.wait(until: $0) })
        do {
            for _ in 0..<count { fixtures.append(try await makeFixture()) }
            try await run(fixtures, controller, gate)
        } catch {
            await controller.stop().value
            for fixture in fixtures { await fixture.stop() }
            throw error
        }
        await controller.stop().value
        for fixture in fixtures { await fixture.stop() }
    }

    private func makeFixture() async throws -> Fixture {
        let transport = PerformanceAuditTransport(bodyDelay: .seconds(30))
        let gmail = AuditGmail(performanceTransport: transport, performanceFixtureCount: 200)
        let indices = [1, 3, 5]
        _ = await gmail.modifyThreads(ids: indices.map { "performance-thread-\($0)" },
            addLabelIDs: [SystemLabel.unread], removeLabelIDs: [])
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            let updates = indices.map { index in
                CacheTransaction.MessageUpdate(record: MessageRecord(accountID: "ui-audit", id: "performance-\(index)",
                    threadID: "performance-thread-\(index)", historyID: 1, date: Date(timeIntervalSince1970: Double(index)),
                    snippet: "", sender: "sender@example.invalid", recipients: "reader@example.invalid", cc: nil,
                    subject: "Synthetic prefetch", sizeEstimate: 1), labelIDs: [SystemLabel.inbox, SystemLabel.unread])
            }
            try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: "ui-audit")
        }
        let suite = "MessagePrefetchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let account = AccountRecord(id: "ui-audit", email: "reader@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: gmail,
            outgoingDirectory: FileManager.default.temporaryDirectory,
            listPreferences: MessageListPreferences(defaults: defaults))
        // No sync loop, windows, or real account clients are started.
        return Fixture(mailbox: mailbox, transport: transport, defaults: defaults, suite: suite)
    }

    private func body(_ index: Int, in fixture: Fixture) async throws -> MessageBodyRecord? {
        try await fixture.mailbox.cache.read { try $0.body(messageID: "performance-\(index)", accountID: "ui-audit") }
    }

    private func hasPrepared(_ index: Int, in fixture: Fixture) async throws -> Bool {
        let messageID = "performance-\(index)"
        let source = try await fixture.mailbox.cache.read { tx in
            (try tx.body(messageID: messageID, accountID: "ui-audit"),
             ReadingResourceSnapshot(resources: try tx.mimeResources(messageID: messageID, accountID: "ui-audit")))
        }
        guard let body = source.0 else { return false }
        let defaults = UserDefaults.standard
        let images = !(defaults.object(forKey: ReadingPreferences.blockImagesKey) as? Bool ?? true)
        let rules = await RemoteContentBlocker.ruleList(allowsRemoteImages: images)
        let key = ReaderPreparationKey(accountID: "ui-audit", owner: ObjectIdentifier(fixture.mailbox.accounts[0]),
            messageID: messageID, body: ReaderBodyVersion(body), resourcesRevision: source.1.revision,
            allowsImages: images, textOnly: rules == nil,
            textScale: ReadingPreferences.textScale(defaults.object(forKey: ReadingPreferences.textScaleKey) as? Double ?? 1))
        return ReaderPreparedCache.shared.value(for: key)?.searchableText.isEmpty == false
    }

    private func expectNoReadingSideEffects(in fixture: Fixture, opened: String? = nil) async throws {
        #expect(try await fixture.mailbox.cache.read { try $0.allActions(accountID: "ui-audit").isEmpty })
        for index in [1, 3, 5] {
            #expect(try await fixture.mailbox.cache.read {
                try $0.thread(id: "performance-thread-\(index)", accountID: "ui-audit")?.isUnread
            } == true)
        }
        let candidates = try await fixture.mailbox.cache.evictionCandidates(keeping: [], now: .now)
        #expect(candidates.count == 3)
        for candidate in candidates {
            #expect((candidate.lastOpenedAt != nil) == (candidate.thread.threadID == opened))
        }
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(try await condition())
    }
}

/// Holds the scheduling boundary without depending on wall-clock test timing.
private actor PrefetchSettleGate {
    private(set) var deadlines: [ContinuousClock.Instant] = []
    private(set) var cancellations = 0
    private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]

    func wait(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        let id = deadlines.count
        deadlines.append(deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting[id] = $0 }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func releaseLatest() {
        waiting.removeValue(forKey: deadlines.count - 1)?.resume()
    }

    private func cancel(_ id: Int) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        cancellations += 1
        continuation.resume(throwing: CancellationError())
    }
}
