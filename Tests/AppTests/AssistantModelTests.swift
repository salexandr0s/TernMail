import Foundation
import MailStore
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct AssistantModelTests {
    @Test func toolResultsAndValidatedSourcesContinueTheConversation() async throws {
        let source = Self.source("a")
        let call = AIToolCall(id: "read-1", namespace: "tern", name: "read_thread", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [.complete(Self.callResponse(call)), .complete(Self.answer("The deadline is Friday."))])
        let fixture = try Fixture(provider: provider, execute: { _ in
            .init(data: .object(["body": .string("Send the proposal Friday."), "source_id": .string(source.id)]), sources: [source])
        })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("What do I owe?")
        await fixture.model.waitForCurrentTurn()

        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.sources == [source])
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[1].input.contains { $0["type"]?.stringValue == "function_call_output" && $0["call_id"]?.stringValue == "read-1" })
        #expect(try requests[1].input.last?.jsonString().contains("Send the proposal Friday.") == true)
    }

    @Test func revokingAnAccountClearsDisplayAndProviderHistory() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Private answer.")), .complete(Self.answer("New account answer."))])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Private account question")
        await fixture.model.waitForCurrentTurn()
        fixture.model.composerText = "Private draft prompt"

        fixture.model.setAccountEnabled("a", enabled: false)
        #expect(fixture.model.messages.isEmpty)
        #expect(fixture.model.composerText.isEmpty)
        fixture.model.setAccountEnabled("b", enabled: true)
        fixture.context.currentAccounts = ["b"]
        fixture.model.refreshAccess()
        fixture.model.send("New account question")
        await fixture.model.waitForCurrentTurn()

        let last = try #require(await provider.requests.last)
        #expect(last.input.count == 1)
        #expect(try AIJSON.array(last.input).jsonString().contains("Private") == false)
        #expect(last.instructions.contains("b@example.invalid"))
        #expect(!last.instructions.contains("a@example.invalid"))
    }

    @Test func effectiveAccountScopeIgnoresUnrelatedSelectionChanges() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Answer."))])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Question")
        await fixture.model.waitForCurrentTurn()
        fixture.context.selectedThreads = [.init(accountID: "a", threadID: "other")]
        fixture.model.refreshAccess()
        #expect(fixture.model.messages.count == 2)

        fixture.context.revision += 1
        fixture.model.refreshAccess()
        #expect(fixture.model.messages.isEmpty)
        #expect(fixture.model.models.isEmpty)
    }

    @Test func restoredAccountOptInsSurviveUntilTheMailboxLoads() async throws {
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer("Ready."))])
        let fixture = try Fixture(provider: provider, accountsReady: false, restoredAccountIDs: ["a", "removed"])
        defer { fixture.clean() }

        // A hosted MainView can create the real coordinator before AppModel has
        // opened any mailbox. Its refresh must leave the same preferences intact.
        let loadingApp = AppModel()
        let loadingModel = AssistantModel(app: loadingApp, connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
                                          provider: provider, defaults: fixture.defaults)
        loadingModel.refreshAccess()
        #expect(loadingModel.enabledAccountIDs == ["a", "removed"])

        await fixture.model.refreshConnection()
        #expect(fixture.model.enabledAccountIDs == ["a", "removed"])
        #expect(fixture.defaults.stringArray(forKey: "assistant.enabledAccounts") == ["a", "removed"])
        fixture.model.send("Read while loading")
        #expect(!fixture.model.isRunning)
        #expect(await provider.requests.isEmpty)

        fixture.context.isAccountListReady = true
        fixture.model.refreshAccess()
        #expect(fixture.model.enabledAccountIDs == ["a"])
        #expect(fixture.defaults.stringArray(forKey: "assistant.enabledAccounts") == ["a"])
        fixture.model.send("Read now")
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.state == .completed)

        fixture.model.setAccountEnabled("a", enabled: false)
        #expect(fixture.model.enabledAccountIDs.isEmpty)
        #expect(fixture.defaults.stringArray(forKey: "assistant.enabledAccounts") == [])
    }

    @Test func defaultHostedPreferencesCannotChangeStandardDefaults() throws {
        try #require(AssistantRuntimeEnvironment.isTestHost)
        let standard = UserDefaults.standard
        let originalAccounts = standard.stringArray(forKey: "assistant.enabledAccounts")
        let originalModel = standard.string(forKey: "assistant.selectedModel")
        let app = AppModel()
        let context = Context()
        let provider = AssistantProviderFixture(replies: [])
        let model = AssistantModel(app: app, provider: provider, context: { context.value() })
        #expect(model.enabledAccountIDs.isEmpty)
        #expect(model.selectedModelID.isEmpty)
        model.setAccountEnabled("a", enabled: true)
        model.selectedModelID = "isolated-hosted-model"
        model.refreshAccess()
        #expect(model.enabledAccountIDs == ["a"])

        let second = AssistantModel(app: app, provider: provider, context: { context.value() })
        #expect(second.enabledAccountIDs.isEmpty)
        #expect(second.selectedModelID.isEmpty)
        model.setAccountEnabled("a", enabled: false)
        let standardWasChanged = originalAccounts != standard.stringArray(forKey: "assistant.enabledAccounts")
            || originalModel != standard.string(forKey: "assistant.selectedModel")
        #expect(!standardWasChanged)
    }

    @Test func cancellationAndRevocationRejectLateStreamEvents() async throws {
        let provider = AssistantProviderFixture(replies: [.suspended, .suspended])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Read this")
        await provider.waitForRequests(1)
        fixture.model.stop()
        await provider.release(Self.answer("Late text"))
        #expect(fixture.model.messages.last?.state == .cancelled)
        #expect(fixture.model.messages.last?.text != "Late text")

        fixture.model.send("Read again")
        await provider.waitForRequests(2)
        fixture.context.instances = [:]
        fixture.model.refreshAccess()
        await provider.release(Self.answer("Excluded text"))
        #expect(fixture.model.messages.isEmpty)
        #expect(!fixture.model.isRunning)
    }

    @Test func interruptedStreamNeverCompletesTheMessage() async throws {
        let provider = AssistantProviderFixture(replies: [.interrupted("Partial answer")])
        let fixture = try Fixture(provider: provider)
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Question")
        await fixture.model.waitForCurrentTurn()
        #expect(fixture.model.messages.last?.text == "Partial answer")
        #expect(fixture.model.messages.last?.state == .failed)
        #expect(fixture.model.errorMessage != nil)
    }

    @Test func completedDraftSurvivesCancellationDuringTheNextTool() async throws {
        let draft = AIToolCall(id: "draft", namespace: "tern", name: "prepare_draft", arguments: "{}")
        let read = AIToolCall(id: "read", namespace: "tern", name: "read_thread", arguments: "{}")
        let calls = [draft, read]
        let response = AIResponse(output: calls.flatMap { Self.callResponse($0).output }, text: "", toolCalls: calls)
        let provider = AssistantProviderFixture(replies: [.complete(response), .complete(Self.answer("Your draft is already prepared."))])
        let pause = ToolPause()
        var draftCount = 0
        let fixture = try Fixture(provider: provider, execute: { call in
            if call.name == "prepare_draft" {
                draftCount += 1
                return .init(data: .object(["draft_id": .string("saved-draft")]), createdDraftID: "saved-draft")
            }
            await pause.wait()
            return .init(data: .null)
        })
        defer { fixture.clean(); pause.release() }
        await fixture.model.refreshConnection()
        fixture.model.send("Prepare a draft, then read the other thread")
        await pause.waitUntilStarted()
        #expect(fixture.model.messages.last?.draftIDs == ["saved-draft"])
        fixture.model.stop()
        pause.release()
        fixture.model.send("Continue")
        await fixture.model.waitForCurrentTurn()

        let requests = await provider.requests
        #expect(requests.count == 2)
        let resumed = try #require(requests.last)
        let outputs = resumed.input.filter { $0["type"]?.stringValue == "function_call_output" }
        #expect(outputs.count == 2)
        #expect(outputs.first?["output"]?.stringValue?.contains("saved-draft") == true)
        #expect(outputs.last?["output"]?.stringValue?.contains("not completed") == true)
        #expect(draftCount == 1)
        #expect(fixture.model.messages.last?.state == .completed)
    }

    @Test func attachmentFailureKeepsItsSpecificLimitation() async throws {
        let call = AIToolCall(id: "pdf", namespace: "tern", name: "read_attachment", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [.complete(Self.callResponse(call)), .complete(Self.answer("This PDF requires OCR."))])
        let fixture = try Fixture(provider: provider, execute: { _ in throw AttachmentTextReader.ReadError.noPDFText })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Read the PDF")
        await fixture.model.waitForCurrentTurn()
        let resumed = try #require(await provider.requests.last)
        #expect(resumed.input.last?["output"]?.stringValue?.contains("OCR is not available") == true)
        #expect(fixture.model.messages.last?.state == .completed)
    }

    @Test(arguments: [false, true])
    func cancelledToolDeliveryIsAcknowledgedOnlyByItsAcceptingTurn(startNewChat: Bool) async throws {
        let first = AIToolCall(id: "abandoned", namespace: "tern", name: "prepare_draft", arguments: "{}")
        let retry = AIToolCall(id: "retry", namespace: "tern", name: "prepare_draft", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [
            .complete(Self.callResponse(first)), .complete(Self.callResponse(retry)),
            .complete(Self.answer("Your draft is prepared.")),
        ])
        var acknowledged: [String] = []
        weak var model: AssistantModel?
        let fixture = try Fixture(provider: provider, acknowledge: { acknowledged.append($0) }, execute: { call in
            if call.id == first.id {
                // Reproduce Stop after a successful tool operation but before its
                // caller resumes, with the next turn already owning the model.
                if startNewChat { model?.newChat() } else { model?.stop() }
                model?.send("Continue")
            }
            return .init(data: .object(["draft_id": .string("saved-draft")]), createdDraftID: "saved-draft")
        })
        defer { fixture.clean() }
        model = fixture.model
        await fixture.model.refreshConnection()
        fixture.model.send("Prepare a draft")
        await provider.waitForRequests(2)
        await fixture.model.waitForCurrentTurn()

        #expect(acknowledged == [retry.id])
        #expect(fixture.model.messages.last?.state == .completed)
        #expect(fixture.model.messages.last?.draftIDs == ["saved-draft"])
        let requests = await provider.requests
        #expect(requests.count == 3)
        #expect(try AIJSON.array(requests[1].input).jsonString().contains("saved-draft") == false)
        #expect(requests[2].input.last?["output"]?.stringValue?.contains("saved-draft") == true)
        if startNewChat {
            #expect(fixture.model.messages.count == 2)
            #expect(requests[1].input.count == 1)
        } else {
            #expect(fixture.model.messages[1].state == .cancelled)
            #expect(fixture.model.messages[1].draftIDs.isEmpty)
        }
    }

    @Test func invalidNamespaceCannotReachToolExecution() async throws {
        let call = AIToolCall(id: "bad", namespace: "external", name: "read_thread", arguments: "{}")
        let provider = AssistantProviderFixture(replies: [.complete(Self.callResponse(call))])
        var calls = 0
        let fixture = try Fixture(provider: provider, execute: { _ in calls += 1; return .init(data: .null) })
        defer { fixture.clean() }
        await fixture.model.refreshConnection()
        fixture.model.send("Question")
        await fixture.model.waitForCurrentTurn()
        #expect(calls == 0)
        #expect(fixture.model.messages.last?.state == .failed)
    }

    @Test func structuredSummaryRejectsInventedEvidence() async throws {
        let source = Self.source("a")
        func summary(_ sourceID: String) throws -> String {
            try AIJSON.object([
                "summary": .string("A proposal is due."), "source_ids": .array([.string(sourceID)]),
                "decisions": .array([]), "open_tasks": .array([
                    .object(["description": .string("Send proposal"), "owner": .null,
                             "due_date": .null, "source_ids": .array([.string(sourceID)])])
                ])
            ]).jsonString()
        }
        let provider = AssistantProviderFixture(replies: [.complete(Self.answer(try summary(source.id))), .complete(Self.answer(try summary("invented")))])
        let tools = AssistantToolSession(definitions: [], execute: { _ in .init(data: .object(["source_id": .string(source.id)]), sources: [source]) })
        let service = AssistantSummaryService(provider: provider, model: "test", tools: tools, isScopeValid: { true })
        let value = try await service.summarize(thread: .init(accountID: "a", threadID: "t"))
        #expect(value.openTasks.count == 1)
        #expect(value.openTasks.first?.owner == nil)
        await #expect(throws: AIProviderError.invalidResponse) {
            try await service.summarize(thread: .init(accountID: "a", threadID: "t"))
        }
        #expect(await provider.requests.first?.responseSchema != nil)
    }

    private static func source(_ account: String) -> AssistantSource {
        .init(accountID: account, threadID: "t", messageID: "m", partID: nil, title: "Proposal")
    }
    private static func answer(_ text: String) -> AIResponse {
        .init(output: [.object(["type": .string("message"), "role": .string("assistant"), "content": .array([
            .object(["type": .string("output_text"), "text": .string(text)])
        ])])], text: text, toolCalls: [])
    }
    private static func callResponse(_ call: AIToolCall) -> AIResponse {
        .init(output: [.object(["type": .string("function_call"), "call_id": .string(call.id),
            "namespace": .string(call.namespace), "name": .string(call.name), "arguments": .string(call.arguments)])], text: "", toolCalls: [call])
    }

    @MainActor private final class Context {
        let accounts = ["a", "b"].map { AccountRecord(id: $0, email: "\($0)@example.invalid", displayName: nil, grantedScopes: [], addedAt: .distantPast) }
        var isAccountListReady = true
        var currentAccounts: Set<String> = ["a"]
        var selectedThreads: Set<ThreadKey> = [.init(accountID: "a", threadID: "t")]
        var instances = ["a": "instance-a", "b": "instance-b"]
        var revision = 1
        func value() -> AssistantContext {
            .init(accounts: isAccountListReady ? accounts : [], isAccountListReady: isAccountListReady,
                  currentAccountIDs: currentAccounts, selectedThreads: selectedThreads,
                  accountInstances: isAccountListReady ? instances : [:], connectionRevision: revision, canUsePlan: true)
        }
    }

    @MainActor private struct Fixture {
        let model: AssistantModel
        let context: Context
        let defaults: UserDefaults
        let domain: String

        init(provider: any AIProvider,
             accountsReady: Bool = true, restoredAccountIDs: [String] = [],
             acknowledge: @escaping @MainActor (String) -> Void = { _ in },
             execute: @escaping @MainActor (AIToolCall) async throws -> MailAssistantToolResult = { _ in .init(data: .null) }) throws {
            domain = "TernAssistantTests." + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: domain))
            defaults.set(restoredAccountIDs, forKey: "assistant.enabledAccounts")
            let context = Context()
            context.isAccountListReady = accountsReady
            self.context = context
            model = AssistantModel(app: AppModel(), connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
                provider: provider, defaults: defaults, context: { context.value() }, makeTools: { _ in
                    .init(definitions: MailAssistantTools.definitions, acknowledge: acknowledge, execute: execute)
                })
            model.selectedScope = .currentAccount
            model.setAccountEnabled("a", enabled: true)
        }
        func clean() { model.stop(); defaults.removePersistentDomain(forName: domain) }
    }

    @MainActor private final class ToolPause {
        private var started = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?
        func wait() async {
            started = true
            startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { waiter = $0 }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
    }
}

private actor AssistantProviderFixture: AIProvider {
    enum Reply: Sendable { case complete(AIResponse), interrupted(String), suspended }
    private var replies: [Reply]
    private(set) var requests: [AIRequest] = []
    private var suspended: AsyncThrowingStream<AIEvent, any Error>.Continuation?
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(replies: [Reply]) { self.replies = replies }
    func models() async throws -> [AIModel] { [.init(id: "test", displayName: "Test model")] }
    nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.start(request, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
    func release(_ response: AIResponse) {
        suspended?.yield(.completed(response)); suspended?.finish(); suspended = nil
    }
    private func start(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
        requests.append(request)
        let ready = requestWaiters.filter { requests.count >= $0.0 }
        requestWaiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard !replies.isEmpty else { continuation.finish(throwing: AIProviderError.invalidResponse); return }
        switch replies.removeFirst() {
        case .complete(let value): continuation.yield(.completed(value)); continuation.finish()
        case .interrupted(let value): continuation.yield(.textDelta(value)); continuation.finish()
        case .suspended: suspended = continuation
        }
    }
}
