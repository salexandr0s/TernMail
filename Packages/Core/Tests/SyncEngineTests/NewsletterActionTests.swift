import Foundation
import GRDB
@testable import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct NewsletterActionTests {
    @Test func snapshotAndConcurrentRequestsLeaveTheActiveClaimIntact() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let id = try await seedNewsletter(cache)
        let transport = HeldNewsletterTransport()
        let request = Task { try await engine.requestNewsletterUnsubscribe(id: id, transport: transport) }
        await transport.waitUntilStarted()
        #expect(try await engine.newsletterSnapshot().subscriptions.first?.status == .requesting)
        await #expect(throws: NewsletterActionError.self) {
            try await engine.requestNewsletterUnsubscribe(id: id, transport: transport)
        }
        await transport.release()
        #expect(try await request.value.status == .requested)
        #expect(await transport.calls == 1)
        #expect(await gmail.changes.isEmpty)
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.isEmpty)
    }

    @Test func cancellationRecordsAnAmbiguousOutcomeWithoutReplaying() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let id = try await seedNewsletter(cache)
        let transport = HeldNewsletterTransport()
        let request = Task { try await engine.requestNewsletterUnsubscribe(id: id, transport: transport) }
        await transport.waitUntilStarted()
        request.cancel()
        await transport.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        let row = try #require(try await engine.newsletterSnapshot().subscriptions.first)
        #expect(row.status == .failed)
        #expect(row.lastError?.contains("may have reached") == true)
        #expect(await transport.calls == 1)
        #expect(try await engine.newsletterSnapshot().subscriptions.first?.status == .failed)
        #expect(await transport.calls == 1)
    }

    @Test func restartingRecoversAbandonedClaimsButNeverResendsThem() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let id = try await seedNewsletter(cache)
        _ = try await cache.write {
            try $0.claimNewsletterRequest(id: id, accountID: account, requestID: "previous:one", now: .now)
        }
        let row = try #require(try await engine.newsletterSnapshot().subscriptions.first)
        #expect(row.status == .failed)
        #expect(row.lastError?.contains("interrupted") == true)
        #expect(try await engine.resetNewsletterStatus(id: id).status == .active)
    }

    @Test func storageFailureRecoversWithoutRestartingOrReplayingTheRequest() async throws {
        let writer = try DatabaseQueue()
        let cache = try MailCache(writer: writer)
        let (engine, _, _, _) = try await makeEngine(cache: cache)
        let id = try await seedNewsletter(cache)
        let transport = HeldNewsletterTransport()
        let request = Task { try await engine.requestNewsletterUnsubscribe(id: id, transport: transport) }
        await transport.waitUntilStarted()
        try await writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER rejectNewsletterOutcome BEFORE UPDATE ON newsletterOutcome
                BEGIN SELECT RAISE(ABORT, 'Synthetic storage failure'); END
                """)
        }
        await transport.release()
        await #expect(throws: NewsletterActionError.self) { try await request.value }
        #expect(try await cache.newsletters(accountID: account).subscriptions.first?.status == .requesting)
        try await writer.write { try $0.execute(sql: "DROP TRIGGER rejectNewsletterOutcome") }
        let recovered = try #require(try await engine.newsletterSnapshot().subscriptions.first)
        #expect(recovered.status == .failed)
        #expect(recovered.lastError?.contains("could not be saved") == true)
        #expect(await transport.calls == 1)
        #expect(try await engine.resetNewsletterStatus(id: id).status == .active)
    }

    @Test func stoppedEngineCannotPublishLateUnsubscribeResultsOrRecreateAnAccount() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let id = try await seedNewsletter(cache)
        let transport = HeldNewsletterTransport()
        let request = Task { try await engine.requestNewsletterUnsubscribe(id: id, transport: transport) }
        await transport.waitUntilStarted()
        let stopping = Task { await engine.stop() }
        while !(await engine.stopRequested.withLock { $0 }) { await Task.yield() }
        await transport.release()
        await stopping.value
        try await cache.write { try $0.deleteAccountData(accountID: account) }
        await #expect(throws: (any Error).self) { try await request.value }
        #expect(try await cache.read { try $0.cachedAccountIDs() }.isEmpty)
    }

    @Test func manualActionsRequireConfirmationAndDoNotUseTheNetwork() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let id = try await seedNewsletter(cache, automatic: false)
        let transport = HeldNewsletterTransport()
        await #expect(throws: NewsletterActionError.self) {
            try await engine.requestNewsletterUnsubscribe(id: id, transport: transport)
        }
        await #expect(throws: NewsletterActionError.self) { try await engine.confirmNewsletterUnsubscribed(id: id) }
        #expect(try await engine.markNewsletterOpened(id: id).status == .opened)
        #expect(try await engine.confirmNewsletterUnsubscribed(id: id).status == .completed)
        #expect(await transport.calls == 0)
        #expect(await gmail.changes.isEmpty)
    }
}

private func seedNewsletter(_ cache: MailCache, automatic: Bool = true) async throws -> String {
    let state = try await cache.write { try $0.beginNewsletterScan(accountID: account) }
    let url = try #require(URL(string: "https://example.com/unsubscribe/token"))
    let message = NewsletterMessage(accountID: account, generation: state.generation, messageID: "newsletter",
        threadID: "thread", date: .now, subject: "Daily news", sender: .init(name: "News", address: "news@example.com"),
        options: .init(listID: "news.example.com", webURL: url, mailtoURL: nil, oneClickURL: automatic ? url : nil))
    let snapshot = try await cache.write { try $0.commitNewsletterPage(state, messages: [message], nextPageToken: nil, now: .now) }
    return try #require(snapshot.subscriptions.first?.id)
}

private actor HeldNewsletterTransport: NewsletterUnsubscribeTransport {
    private(set) var calls = 0
    private var started: [CheckedContinuation<Void, Never>] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func unsubscribe(at url: URL) async throws {
        calls += 1
        let listeners = started
        started = []
        listeners.forEach { $0.resume() }
        await withCheckedContinuation { waiting = $0 }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release() { waiting?.resume(); waiting = nil }
}
