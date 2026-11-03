import AppKit
import Foundation
import GmailAPI
import MailStore
import SyncEngine
import SwiftUI
import Synchronization
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct MailPaginationTests {
    @Test func emptyMailboxChecksGmailAtStartupAndContinuesUntilMailAppears() async throws {
        let transport = MailPaginationTransport()
        let mailbox = try await emptyMailbox(transport: transport)
        let window = host(mailbox)
        defer { window.close() }
        // The view mounts before account startup restores hasSyncedOnce.
        await mailbox.start()
        try await settled { mailbox.listItems.count == 1 }
        #expect(mailbox.listItems.first?.id.threadID == "remote")
        // The first ten pages and the next page produce no database changes.
        // Mail on page 12 must appear before the next cursor is requested.
        #expect(await transport.pageTokens == (0..<12).map(String.init))
        #expect(mailbox.older?.state == .more)
        await mailbox.stop()
    }

    @Test(arguments: [404, 429]) func emptyMailboxLeavesFailedPagesForManualRetry(status: Int) async throws {
        let transport = MailPaginationTransport(failureStatus: status)
        let mailbox = try await emptyMailbox(transport: transport)
        let window = host(mailbox)
        defer { window.close() }
        await mailbox.start()
        let failure: GmailPager.State = status == 429 ? .busy : .failed
        try await settled { mailbox.older?.state == failure }
        let attempts = await transport.pageTokens.count
        mailbox.listPreferences.filters = [.unread]
        mailbox.listPreferences.filters = []
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.pageTokens.count == attempts)
        mailbox.loadOlderConversations()
        try await settled { mailbox.older?.state == failure }
        #expect(await transport.pageTokens.count > attempts)
        await mailbox.stop()
    }

    @Test(arguments: [true, false]) func emptyMailboxStopsAtGmailExhaustionAndRespectsPausedAccounts(syncEnabled: Bool) async throws {
        let transport = MailPaginationTransport(isEmpty: true)
        let mailbox = try await emptyMailbox(transport: transport, syncEnabled: syncEnabled)
        let window = host(mailbox)
        defer { window.close() }
        await mailbox.start()
        if syncEnabled {
            try await settled { mailbox.older?.state == .finished }
        } else {
            try await settled { mailbox.isListPresentationReady && mailbox.selectedHaveSyncedOnce }
        }
        mailbox.listPreferences.filters = [.unread]
        mailbox.listPreferences.filters = []
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.pageTokens.count == (syncEnabled ? 1 : 0))
        #expect(mailbox.listItems.isEmpty)
        await mailbox.stop()
    }

    @Test func pausedMailboxCanFindFilteredMailBeyondItsFirstLocalPage() async throws {
        let transport = MailPaginationTransport(isEmpty: true)
        let mailbox = try await emptyMailbox(transport: transport, syncEnabled: false)
        let pageSize = MailboxModel.pageSize
        try await mailbox.cache.write { tx in
            let updates = (0...pageSize).map { index in
                let message = MessageRecord(accountID: "a", id: "m\(index)", threadID: "t\(index)", historyID: 200,
                    date: Date(timeIntervalSince1970: 1_790_000_000 - Double(index)), snippet: "", sender: "",
                    recipients: "", cc: nil, subject: "Cached mail", sizeEstimate: 0)
                let labels = index == pageSize ? [SystemLabel.inbox, SystemLabel.unread] : [SystemLabel.inbox]
                return CacheTransaction.MessageUpdate(record: message, labelIDs: labels)
            }
            try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: "a")
        }
        mailbox.listPreferences.filters = [.unread]
        let window = host(mailbox)
        defer { window.close() }
        await mailbox.start()
        try await settled { mailbox.listItems.count == 1 }
        #expect(mailbox.listItems.first?.id.threadID == "t\(MailboxModel.pageSize)")
        #expect(await transport.pageTokens.isEmpty)
        #expect(mailbox.older == nil)
        await mailbox.stop()
    }

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

    private func emptyMailbox(transport: MailPaginationTransport, syncEnabled: Bool = true) async throws -> MailboxModel {
        let cache = try MailCache.inMemory()
        try await cache.write { try $0.saveCursor(historyID: 200, accountID: "a", fullSyncAt: .now) }
        // Advance the synthetic request clock instead of waiting through the
        // Gmail client's own bounded rate-limit retries in the failure test.
        let time = Mutex<TimeInterval>(0)
        let budget = GmailRequestBudget(now: { time.withLock { $0 } }, sleep: { duration in
            time.withLock { $0 += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
            await Task.yield()
        })
        let defaults = try #require(UserDefaults(suiteName: "tern.pagination.\(UUID().uuidString)"))
        return MailboxModel(account: .init(id: "a", email: "a@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now),
            cache: cache, gmail: GmailClient(tokens: MailPaginationTokens(), transport: transport,
                retryDelays: [], gmailRequestBudget: budget), outgoingDirectory: .temporaryDirectory,
            syncEnabled: syncEnabled, listPreferences: MessageListPreferences(defaults: defaults))
    }

    private func host(_ mailbox: MailboxModel) -> NSWindow {
        let controller = NSHostingController(rootView: ThreadListView(mailbox: mailbox)
            .frame(width: 520, height: 540).environment(AppModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil)
        return window
    }

    private func settled(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

private struct MailPaginationTokens: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "pagination-test-token" }
}

/// Only threads.list pages and their one metadata response vary; startup
/// receives an already-synced, empty synthetic Gmail account.
private actor MailPaginationTransport: HTTPTransport {
    let failureStatus: Int?
    let isEmpty: Bool
    private(set) var pageTokens: [String] = []

    init(failureStatus: Int? = nil, isEmpty: Bool = false) {
        self.failureStatus = failureStatus
        self.isEmpty = isEmpty
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        var status = 200
        var contentType = "application/json"
        let body: String
        switch url.lastPathComponent {
        case "threads":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let token = query.first { $0.name == "pageToken" }?.value ?? "0"
            pageTokens.append(token)
            if let failureStatus {
                status = failureStatus
                body = "{}"
            } else if isEmpty {
                body = #"{"threads":[]}"#
            } else if let page = Int(token), page < 11 {
                body = #"{"threads":[],"nextPageToken":"\#(page + 1)"}"#
            } else {
                body = #"{"threads":[{"id":"remote"}],"nextPageToken":"12"}"#
            }
        case "v1" where url.path == "/batch/gmail/v1":
            contentType = "multipart/mixed; boundary=pagination"
            let thread = #"{"id":"remote","messages":[{"id":"message","threadId":"remote","historyId":"200","internalDate":"1790000000000","labelIds":["INBOX"],"payload":{"headers":[{"name":"Subject","value":"Remote mail"}]}}]}"#
            body = "--pagination\r\nContent-Type: application/http\r\nContent-ID: <response-item-0>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n\(thread)\r\n--pagination--\r\n"
        case "history": body = #"{"history":[],"historyId":"200"}"#
        case "profile": body = #"{"emailAddress":"a@example.invalid","historyId":"200"}"#
        case "labels": body = #"{"labels":[]}"#
        default: body = "{}"
        }
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": contentType]))
        return (Data(body.utf8), response)
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
