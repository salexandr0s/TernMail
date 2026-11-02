import Foundation
import GmailAPI
import MailStore
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct MailPaginationTests {
    @Test func successfulAccountContinuesWhileAnotherRetriesItsOwnCursor() async throws {
        let a = PageReplies([.success(.init(threadIDs: ["a1"], nextPageToken: "a-next")),
            .success(.init(threadIDs: ["a2"], nextPageToken: nil))])
        let b = PageReplies([.failure(.notFound), .success(.init(threadIDs: ["b1"], nextPageToken: nil))])
        let pager = GmailPager(sources: ["a": { try await a.fetch($0) }, "b": { try await b.fetch($0) }])
        var received: [ThreadKey] = []
        pager.next { received += $0 }
        try await settled { pager.state == .failed }
        #expect(received == [.init(accountID: "a", threadID: "a1")])
        #expect(pager.failedAccountIDs == ["b"])
        pager.next { received += $0 }
        try await settled { pager.state == .finished }
        #expect(Set(received) == [.init(accountID: "a", threadID: "a1"),
            .init(accountID: "a", threadID: "a2"), .init(accountID: "b", threadID: "b1")])
        #expect(await a.tokens == [nil, "a-next"])
        #expect(await b.tokens == [nil, nil])
        #expect(pager.failedAccountIDs.isEmpty)
    }

    @Test func cancellationIgnoresAProviderCompletionThatArrivesLate() async throws {
        let gate = PageGate()
        let pager = GmailPager(accountID: "a") { _ in await gate.fetch() }
        var received: [ThreadKey] = []
        pager.next { received += $0 }
        while await !gate.isWaiting { await Task.yield() }
        pager.cancel()
        await gate.resume()
        for _ in 0..<30 { await Task.yield() }
        #expect(received.isEmpty)
        #expect(pager.threadIDs(in: "a").isEmpty)
        #expect(pager.revision == 0)
    }

    @Test func inboxCombinedAndScopedMailboxesHaveIndependentCoverage() async throws {
        let cache = try MailCache.inMemory()
        let a = AccountRecord(id: "a", email: "a@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let b = AccountRecord(id: "b", email: "b@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: a, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: .temporaryDirectory, syncEnabled: false)
        await mailbox.addAccount(b, gmail: AuditGmail(.second), syncEnabled: false)
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        #expect(mailbox.offersOlderConversations)
        mailbox.loadOlderConversations()
        let combined = try #require(mailbox.older)
        try await settled { combined.state == .finished }
        #expect(!combined.threadIDs(in: "a").isEmpty)
        #expect(!combined.threadIDs(in: "b").isEmpty)
        #expect(!mailbox.offersOlderConversations)

        mailbox.selectedMailbox = .scoped(SystemLabel.inbox, ["a", "b"])
        #expect(mailbox.older == nil)
        #expect(mailbox.offersOlderConversations)
        mailbox.loadOlderConversations()
        let scoped = try #require(mailbox.older)
        mailbox.applyAccountPresentation(preferences: [], visibleAccountIDs: ["a"])
        #expect(mailbox.older == nil)
        #expect(mailbox.offersOlderConversations)
        mailbox.loadOlderConversations()
        let visible = try #require(mailbox.older)
        #expect(visible !== scoped)
        try await settled { visible.state == .finished }
        #expect(visible.threadIDs(in: "b").isEmpty)
        mailbox.search.update("x")
        try await settled { mailbox.older == nil }
        #expect(!mailbox.offersOlderConversations)
        await mailbox.stop()
    }

    private func settled(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

private actor PageReplies {
    let replies: [Result<GmailResultPage, GmailError>]
    private(set) var tokens: [String?] = []
    init(_ replies: [Result<GmailResultPage, GmailError>]) { self.replies = replies }
    func fetch(_ token: String?) throws -> GmailResultPage {
        let index = tokens.count
        tokens.append(token)
        return try replies[index].get()
    }
}

private actor PageGate {
    private var continuation: CheckedContinuation<GmailResultPage, Never>?
    var isWaiting: Bool { continuation != nil }
    func fetch() async -> GmailResultPage { await withCheckedContinuation { continuation = $0 } }
    func resume() {
        continuation?.resume(returning: .init(threadIDs: ["stale"], nextPageToken: "stale-token"))
        continuation = nil
    }
}
