import Foundation
import Testing
@testable import Tern

@Suite @MainActor struct MailSpotlightRemovalTests {
    @Test func failedPrivacyRemovalSurvivesRelaunchAndExplicitRetryClearsIt() async throws {
        let name = "tern.tests.spotlight-removal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = RemovalTransport()
        let first = MailSpotlightRemoval(defaults: defaults, remove: { try await transport.remove($0) })
        first.requestAll()
        #expect(await first.performPending() == false)
        #expect(first.hasPendingRemoval)
        #expect(first.error != nil)

        let restored = MailSpotlightRemoval(defaults: defaults, remove: { try await transport.remove($0) })
        #expect(restored.hasPendingRemoval)
        await transport.allowRemoval()
        #expect(await restored.performPending())
        #expect(!restored.hasPendingRemoval)
        #expect(restored.error == nil)
        #expect(!MailSpotlightRemoval(defaults: defaults).hasPendingRemoval)
        #expect(await transport.calls == [nil, nil])
    }

    @Test func accountRemovalAddedDuringAnOSCallIsNotForgotten() async throws {
        let name = "tern.tests.spotlight-removal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let transport = RemovalTransport()
        await transport.allowRemoval()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (waiting, resume) = AsyncStream<Void>.makeStream()
        let removal = MailSpotlightRemoval(defaults: defaults, remove: { accounts in
            try await transport.remove(accounts)
            if await transport.calls.count == 1 {
                start.yield(())
                for await _ in waiting {}
            }
        })
        removal.request(accounts: ["first"])
        let task = Task { await removal.performPending() }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        removal.request(accounts: ["second"])
        resume.finish()
        #expect(await task.value)
        #expect(await transport.calls == [["first"], ["first", "second"]])
        #expect(!removal.hasPendingRemoval)
        start.finish()
    }

    @Test func removingOneAccountKeepsOtherAccountsStaleItemsEligibleForDeletion() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let accountID = mailbox.defaultAccount.account.id
        let name = "tern.tests.spotlight-index.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: MailSpotlightIndexer.enabledKey)
        let transport = RemovalTransport()
        await transport.allowRemoval()
        let removal = MailSpotlightRemoval(defaults: defaults, remove: { try await transport.remove($0) })
        let (passes, observePass) = AsyncStream<[String: Int]>.makeStream()
        let indexer = MailSpotlightIndexer(app: app, defaults: defaults, removal: removal,
            reindex: { _, _, known in
                observePass.yield(known)
                // The first pass indexes mail; the next sees it move out of
                // the searchable list and needs its previous ID to remove it.
                return known.isEmpty ? ["now-trashed-thread": 1] : [:]
            })
        var iterator = passes.makeAsyncIterator()
        indexer.mailSynced(accountID: accountID)
        #expect(await iterator.next() == [:])
        indexer.remove(accountIDs: ["removed-account"])
        indexer.mailSynced(accountID: accountID)
        #expect(await iterator.next() == ["now-trashed-thread": 1])
        #expect(await transport.calls == [["removed-account"]])
        observePass.finish()
        await app.prepareToQuit()
        await mailbox.stop()
        app.accountPreferences?.stop()
    }

    private actor RemovalTransport {
        enum Failure: Error { case unavailable }
        private(set) var calls: [[String]?] = []
        private var fails = true
        func allowRemoval() { fails = false }
        func remove(_ accounts: [String]?) throws {
            calls.append(accounts)
            if fails { throw Failure.unavailable }
        }
    }
}
