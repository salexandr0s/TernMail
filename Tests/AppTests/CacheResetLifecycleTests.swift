import Foundation
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct CacheResetLifecycleTests {
    @Test func resetRefusesARecoverableDraftBeforeStoppingTheMailbox() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let cache = try #require(app.cache)
        let draft = try await mailbox.defaultAccount.engine.startMessage()
        do {
            try await app.resetMailCache()
            Issue.record("Reset accepted an unsent draft")
        } catch CacheMaintenanceError.recoverableWork(let readiness) {
            #expect(readiness.localDraftCount == 1)
        }
        #expect(app.mailbox === mailbox)
        #expect(try await cache.read { try $0.localDraft(id: draft.id) } != nil)
        await stop(app)
    }

    @Test func resetRecreatesRuntimesAndKeepsAccountSetup() async throws {
        let app = AppModel()
        await app.start()
        let original = try #require(app.mailbox)
        let store = try #require(app.settingsAccountStore)
        let cache = try #require(app.cache)
        let id = original.account.id
        _ = try await store.updateMailPreferences(accountID: id) { $0.nickname = "Kept nickname" }
        try await cache.write { tx in
            _ = try tx.upsertMessages([.init(record: MessageRecord(accountID: id, id: "disposable",
                threadID: "old-thread", historyID: 1, date: .distantPast, snippet: "", sender: "sender@example.invalid",
                recipients: "audit@example.invalid", cc: nil, subject: "Cached only", sizeEstimate: 1), labelIDs: [])])
        }
        try await app.resetMailCache()
        #expect(app.mailbox != nil)
        #expect(app.mailbox !== original)
        #expect(try await store.mailPreferences(accountID: id).nickname == "Kept nickname")
        #expect(try await cache.read { try $0.message(id: "disposable", accountID: id) } == nil)
        #expect(!app.isResettingCache)
        await stop(app)
    }

    private func stop(_ app: AppModel) async {
        await app.prepareToQuit()
        await app.mailbox?.stop()
        app.accountPreferences?.stop()
    }
}
