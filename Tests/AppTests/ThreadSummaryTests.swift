import Foundation
import MailStore
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct ThreadSummaryTests {
    private static let key = ThreadKey(accountID: "a", threadID: "t")
    private static let source = AssistantSource(accountID: "a", threadID: "t", messageID: "m", partID: nil, title: "Proposal")

    @Test func revisionIgnoresPresentationChangesButTracksContentAndDrafts() async throws {
        let cache = try MailCache.inMemory()
        let record = MessageRecord(accountID: "a", id: "m", threadID: "t", historyID: 1,
            date: .distantPast, snippet: "Please review.", sender: "sender@example.invalid",
            recipients: "a@example.invalid", cc: nil, subject: "Proposal", sizeEstimate: 100)
        try await cache.write {
            _ = try $0.upsertMessages([.init(record: record, labelIDs: [SystemLabel.inbox])])
            try $0.rebuildThreads(["t"], accountID: "a")
        }
        var iterator = cache.thread(accountID: "a", threadID: "t").makeAsyncIterator()
        let first = try await iterator.next()
        var detail = try #require(first ?? nil)
        let initial = ThreadSummaryModel.revision(for: detail)
        detail.thread.isUnread.toggle()
        detail.thread.isStarred.toggle()
        detail.messages[0].labels = [SystemLabel.starred, SystemLabel.unread, "custom"]
        detail.messages[0].record.historyID += 1
        detail.messages[0].body = .init(accountID: "a", messageID: "m", html: nil, plainText: "Hydrated body", fetchedAt: .now)
        #expect(ThreadSummaryModel.revision(for: detail) == initial)
        detail.messages[0].draftID = "draft"
        let draft = ThreadSummaryModel.revision(for: detail)
        #expect(draft != initial)
        detail.messages[0].record.snippet = "A revised request."
        #expect(ThreadSummaryModel.revision(for: detail) != draft)
        detail.messages.append(detail.messages[0])
        detail.messages[1].record.id = "new-message"
        detail.thread.messageCount += 1
        #expect(ThreadSummaryModel.revision(for: detail) != initial)
    }

    @Test func cacheReusesNavigationButNeverBypassesScopeOrAccessChanges() async throws {
        let provider = SummaryProvider(replies: try (1...7).map { try Self.response("Summary \($0)") })
        let fixture = Fixture(provider: provider)
        await fixture.model.refreshConnection()
        let first = try await fixture.model.readerSummary(thread: Self.key, revision: "r1")
        fixture.context.selectedThreads = [.init(accountID: "a", threadID: "other")]
        fixture.model.refreshAccess()
        await #expect(throws: AssistantError.self) {
            try await fixture.model.readerSummary(thread: Self.key, revision: "r1")
        }
        fixture.context.selectedThreads = [Self.key]
        fixture.model.refreshAccess()
        #expect(try await fixture.model.readerSummary(thread: Self.key, revision: "r1") == first)
        #expect(await provider.requests.count == 1)
        let updated = try await fixture.model.readerSummary(thread: Self.key, revision: "r2")
        #expect(updated.summary.summary == "Summary 2")
        _ = try await fixture.model.readerSummary(thread: Self.key, revision: "r2", forceRefresh: true)
        fixture.model.setAccountEnabled("a", enabled: false)
        fixture.model.setAccountEnabled("a", enabled: true)
        _ = try await fixture.model.readerSummary(thread: Self.key, revision: "r2")
        fixture.context.instance = "replacement-account"
        fixture.model.refreshAccess()
        _ = try await fixture.model.readerSummary(thread: Self.key, revision: "r2")
        fixture.model.selectedModelID = "alternate"
        _ = try await fixture.model.readerSummary(thread: Self.key, revision: "r2")
        fixture.context.connectionRevision += 1
        await fixture.model.refreshConnection()
        _ = try await fixture.model.readerSummary(thread: Self.key, revision: "r2")
        #expect(await provider.requests.count == 7)
        #expect(fixture.context.reads == 7)
        #expect(fixture.model.messages.isEmpty)
        #expect(!fixture.model.isRunning)
    }

    @Test(arguments: ["model", "revoked", "account", "connection", "cancel"])
    func inFlightSummaryRejectsChangedAccessAndCancellation(change: String) async throws {
        let provider = SummaryProvider(replies: [nil, try Self.response("Fresh summary")])
        let fixture = Fixture(provider: provider)
        await fixture.model.refreshConnection()
        let reader = ThreadSummaryModel()
        let pending = Task { await reader.load(key: Self.key, revision: "r1", assistant: fixture.model) }
        await provider.waitForRequests(1)
        #expect(reader.isLoading)
        switch change {
        case "model":
            fixture.model.selectedModelID = "alternate"
            fixture.model.selectedModelID = "test"
        case "revoked": fixture.model.setAccountEnabled("a", enabled: false)
        case "account": fixture.context.instance = nil; fixture.model.refreshAccess()
        case "connection": fixture.context.connectionRevision += 1; fixture.model.refreshAccess()
        default: pending.cancel()
        }
        await provider.release(0, response: try Self.response("Late private summary"))
        await pending.value
        #expect(reader.report == nil)
        #expect(reader.errorMessage == nil)
        #expect(!reader.isLoading)
        if change == "model" || change == "cancel" {
            await reader.load(key: Self.key, revision: "r1", assistant: fixture.model)
            #expect(reader.report?.summary.summary == "Fresh summary")
            #expect(await provider.requests.count == 2)
            reader.clear()
            #expect(reader.report == nil)
        }
    }

    @Test func newerLoadWinsAndFailureCanRetryWithoutChatState() async throws {
        let provider = SummaryProvider(replies: [nil, try Self.response("New message summary"), .init(output: [], text: "invalid JSON", toolCalls: []), try Self.response("Retried summary")])
        let fixture = Fixture(provider: provider)
        await fixture.model.refreshConnection()
        let reader = ThreadSummaryModel()
        let old = Task { await reader.load(key: Self.key, revision: "old", assistant: fixture.model) }
        await provider.waitForRequests(1)
        await reader.load(key: Self.key, revision: "new", assistant: fixture.model)
        await provider.release(0, response: try Self.response("Older summary"))
        await old.value
        #expect(reader.report?.summary.summary == "New message summary")
        // The old completion must not evict the newer source revision.
        await reader.load(key: Self.key, revision: "new", assistant: fixture.model)
        #expect(await provider.requests.count == 2)
        await reader.load(key: Self.key, revision: "new", assistant: fixture.model, forceRefresh: true)
        #expect(reader.report == nil)
        #expect(reader.errorMessage != nil)
        await reader.load(key: Self.key, revision: "new", assistant: fixture.model, forceRefresh: true)
        #expect(reader.report?.summary.summary == "Retried summary")
        #expect(reader.errorMessage == nil)
        #expect(fixture.model.messages.isEmpty)
    }

    @Test(arguments: ["complete", "thread", "message"])
    func coverageAndCitedLinksComeFromRetrievedEvidence(coverage: String) async throws {
        let extra = AssistantSource(accountID: "a", threadID: "t", messageID: "uncited", partID: nil, title: "Earlier message")
        let provider = SummaryProvider(replies: [try Self.response("A proposal needs review.")])
        let tools = AssistantToolSession(definitions: [], execute: { _ in
            .init(data: .object([
                "truncated": .bool(coverage == "thread"), "total_messages": .number(2),
                "messages": .array([.object(["limitations": .array(coverage == "message" ? [.string("Missing body")] : [])])])
            ]), sources: [Self.source, extra])
        })
        let report = try await AssistantSummaryService(provider: provider, model: "test", tools: tools,
            isScopeValid: { true }).report(thread: Self.key)
        #expect(report.sources == [Self.source])
        #expect(report.messageIDs == ["m", "uncited"])
        #expect(report.totalMessages == 2)
        #expect(throws: ThreadSummaryError.self) { try report.validateMessages(["m", "uncited", "omitted"]) }
        #expect(report.hasPartialCoverage == (coverage != "complete"))
        #expect(await provider.requests.first?.tools.isEmpty == true)
    }

    @Test(arguments: [Set(["older"]), Set(["m", "older"])])
    func mismatchedRemoteMessagesAreNeitherDisplayedNorCached(expectedIDs: Set<String>) async throws {
        let provider = SummaryProvider(replies: [try Self.response("First"), try Self.response("Second")])
        let fixture = Fixture(provider: provider)
        await fixture.model.refreshConnection()
        let reader = ThreadSummaryModel()
        await reader.load(key: Self.key, revision: "local", assistant: fixture.model, expectedMessageIDs: expectedIDs)
        #expect(reader.report == nil)
        #expect(reader.errorMessage != nil)
        await reader.load(key: Self.key, revision: "local", assistant: fixture.model, expectedMessageIDs: ["m"])
        #expect(reader.report?.summary.summary == "Second")
        #expect(await provider.requests.count == 2)
    }

    @Test func readerCreatesItsOwnSessionAlongsideChat() async throws {
        let provider = SummaryProvider(replies: [.init(output: [], text: "Chat response", toolCalls: []), try Self.response("Reader summary")])
        let fixture = Fixture(provider: provider)
        await fixture.model.refreshConnection()
        fixture.model.send("Question")
        await fixture.model.waitForCurrentTurn()
        let chatMessages = fixture.model.messages.map(\.id)
        _ = try await fixture.model.readerSummary(thread: Self.key, revision: "r1")
        #expect(fixture.context.sessions == 2)
        #expect(fixture.model.messages.map(\.id) == chatMessages)
    }

    private static func response(_ text: String) throws -> AIResponse {
        let content = try AIJSON.object([
            "summary": .string(text), "source_ids": .array([.string(source.id)]),
            "decisions": .array([]), "open_tasks": .array([])
        ]).jsonString()
        return .init(output: [], text: content, toolCalls: [])
    }

    @MainActor private final class Context {
        let account = AccountRecord(id: "a", email: "a@example.invalid", displayName: nil, grantedScopes: [], addedAt: .distantPast)
        var selectedThreads: Set<ThreadKey> = [ThreadSummaryTests.key]
        var instance: String? = "account-instance"
        var connectionRevision = 1
        var reads = 0
        var sessions = 0
        func value() -> AssistantContext {
            .init(accounts: [account], isAccountListReady: true, currentAccountIDs: ["a"],
                selectedThreads: selectedThreads, accountInstances: instance.map { ["a": $0] } ?? [:],
                connectionRevision: connectionRevision, canUsePlan: true)
        }
    }

    @MainActor private final class Fixture {
        let app = AppModel()
        let context: Context
        let model: AssistantModel
        init(provider: any AIProvider) {
            let context = Context()
            self.context = context
            model = AssistantModel(app: app, connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
                provider: provider, context: { context.value() }, makeTools: { _ in
                    context.sessions += 1
                    return AssistantToolSession(definitions: [], execute: { call in
                        #expect(call.name == "read_thread")
                        context.reads += 1
                        return .init(data: .object(["truncated": .bool(false), "total_messages": .number(1)]), sources: [ThreadSummaryTests.source])
                    })
                })
            model.setAccountEnabled("a", enabled: true)
        }
    }
}

private actor SummaryProvider: AIProvider {
    private var replies: [AIResponse?]
    private(set) var requests: [AIRequest] = []
    private var suspended: [Int: AsyncThrowingStream<AIEvent, any Error>.Continuation] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(replies: [AIResponse?]) { self.replies = replies }
    func models() async throws -> [AIModel] {
        [.init(id: "test", displayName: "Test"), .init(id: "alternate", displayName: "Alternate")]
    }
    nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.start(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release(_ index: Int, response: AIResponse) {
        let stream = suspended.removeValue(forKey: index)
        stream?.yield(.completed(response)); stream?.finish()
    }
    private func start(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
        let index = requests.count
        requests.append(request)
        let ready = waiters.filter { requests.count >= $0.0 }
        waiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard !replies.isEmpty else { continuation.finish(throwing: AIProviderError.invalidResponse); return }
        if let response = replies.removeFirst() { continuation.yield(.completed(response)); continuation.finish() }
        else { suspended[index] = continuation }
    }
}
