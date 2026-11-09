import AppKit
import Foundation
import MailStore
import MessageContent
import SyncEngine
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct AssistantProviderIntegrationTests {
    @Test func switchingProviderClearsActiveChatAndInvalidatesComposeBeforeRefresh() async throws {
        let provider = Provider(replies: [nil, Self.answer("New answer")])
        let fixture = try Fixture(provider: provider)
        defer { fixture.close() }
        await fixture.model.refreshConnection()
        let compose = try fixture.model.makeComposeSession(accountID: Self.account.id)
        fixture.model.send("Private conversation with the first provider")
        try await provider.waitForRequests(1)
        fixture.model.composerText = "Unsent follow-up"
        let previousAccess = fixture.model.composeAccessRevision

        fixture.model.selectService(.anthropic)

        #expect(!fixture.model.isRunning)
        #expect(fixture.model.messages.isEmpty)
        #expect(fixture.model.composerText.isEmpty)
        #expect(!compose.isValid())
        #expect(fixture.model.composeAccessRevision != previousAccess)
        #expect(fixture.model.enabledAccountIDs == [Self.account.id])
        #expect(!fixture.model.isModelReady)
        await provider.release(0, response: Self.answer("Late private response"))
        await fixture.model.refreshConnection()
        fixture.model.send("New provider question")
        await fixture.model.waitForCurrentTurn()

        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests.last?.input.count == 1)
        #expect(try AIJSON.array(try #require(requests.last?.input)).jsonString().contains("Private conversation") == false)
        #expect(fixture.model.messages.last?.text == "New answer")
    }

    @Test func anOldCatalogueCannotRestoreReadinessAfterProviderSwitch() async throws {
        let provider = Provider(holdFirstCatalogue: true)
        let fixture = try Fixture(provider: provider)
        defer { fixture.close() }
        let oldRefresh = Task { await fixture.model.refreshConnection() }
        try await provider.waitForCatalogue()
        fixture.model.selectService(.deepSeek)
        await provider.releaseCatalogue([.init(id: "old-only", displayName: "Old provider model")])
        await oldRefresh.value

        #expect(fixture.model.models.isEmpty)
        #expect(!fixture.model.isModelReady)
        #expect(fixture.model.selectedModelID.isEmpty)
        await fixture.model.refreshConnection()
        #expect(fixture.model.isModelReady)
        #expect(!fixture.model.models.contains { $0.id == "old-only" })
    }

    @Test func modelChoicesRemainIndependentAndLegacyChatGPTChoiceSurvivesRelaunch() throws {
        let fixture = try Fixture(provider: Provider(), legacyModel: "legacy-model")
        defer { fixture.close() }
        #expect(fixture.model.selectedService == .chatGPT)
        #expect(fixture.model.selectedModelID == "legacy-model")

        fixture.model.selectService(.openAI)
        #expect(fixture.model.selectedModelID.isEmpty)
        fixture.model.selectedModelID = "openai-model"
        fixture.model.selectService(.anthropic)
        fixture.model.selectedModelID = "claude-model"
        fixture.model.selectService(.deepSeek)
        fixture.model.selectedModelID = "deepseek-model"
        fixture.model.selectService(.chatGPT)
        #expect(fixture.model.selectedModelID == "legacy-model")
        fixture.model.selectService(.openAI)
        #expect(fixture.model.selectedModelID == "openai-model")
        fixture.model.selectService(.anthropic)
        #expect(fixture.model.selectedModelID == "claude-model")

        let restarted = AssistantModel(app: AppModel(), connection: ChatGPTConnection(store: VolatileAIConnectionStore()),
            provider: Provider(), defaults: fixture.defaults,
            providerConnection: AssistantProviderConnection(chatGPT: ChatGPTConnection(store: VolatileAIConnectionStore()),
                defaults: fixture.defaults, store: VolatileAPIKeyCredentialStore()))
        #expect(restarted.selectedService == .anthropic)
        #expect(restarted.selectedModelID == "claude-model")
        restarted.selectService(.chatGPT)
        #expect(restarted.selectedModelID == "legacy-model")
    }

    @Test func switchingProviderCancelsPendingSummaryAndDiscardsCachedSummary() async throws {
        let provider = Provider(replies: [try Self.summary("Cached private summary"), nil, try Self.summary("New provider summary")])
        let fixture = try Fixture(provider: provider)
        defer { fixture.close() }
        await fixture.model.refreshConnection()
        let first = try await fixture.model.readerSummary(thread: Self.thread, revision: "r1")
        #expect(first.summary.summary == "Cached private summary")
        let pending = Task {
            try await fixture.model.readerSummary(thread: Self.thread, revision: "r1", forceRefresh: true)
        }
        try await provider.waitForRequests(2)
        fixture.model.selectService(.openAI)
        await #expect(throws: CancellationError.self) { try await pending.value }
        await provider.release(1, response: try Self.summary("Stale summary"))
        await fixture.model.refreshConnection()
        let current = try await fixture.model.readerSummary(thread: Self.thread, revision: "r1")
        #expect(current.summary.summary == "New provider summary")
        #expect(await provider.requests.count == 3)
    }

    @Test func textOnlyModelRejectsComposeImageBeforeInference() async throws {
        let provider = Provider(supportsImages: false)
        let fixture = try Fixture(provider: provider)
        defer { fixture.close() }
        await fixture.model.refreshConnection()
        let cache = try MailCache.inMemory()
        let directory = FileManager.default.temporaryDirectory.appending(path: "ProviderImageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mailbox = MailboxModel(account: Self.account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: directory, syncEnabled: false)
        let draft = LocalDraft(id: UUID().uuidString, accountID: Self.account.id, kind: .new,
            content: .init(subject: "Draft", body: ComposeDocument(plainText: "Original draft"),
                fromAddress: Self.account.email), rfcMessageID: "<draft@example.invalid>", now: .now)
        try await cache.write { try $0.insertLocalDraft(draft) }
        let compose = ComposeModel(localDraftID: draft.id, mailbox: mailbox)
        let model = ComposeAssistantModel(compose: compose, assistant: fixture.model)
        defer { model.clear(); compose.windowClosed() }
        compose.start()
        try await Self.waitUntil { compose.phase == .open }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 160, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = directory.appending(path: "reference.png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
        model.addContextFiles([ComposeDroppedFile(url: image)])
        await model.waitForContextImports()
        #expect(!model.hasContextFileErrors)
        model.prompt = "Describe this image"
        model.send()
        await model.waitForCurrentTurn()

        #expect(model.errorMessage == AIProviderError.unsupportedImages.localizedDescription)
        #expect(model.messages.isEmpty)
        #expect(await provider.requests.isEmpty)
        #expect(compose.content.body.plainText() == "Original draft")
        await compose.requestClose()
        await mailbox.stop()
    }

    private static let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil,
        grantedScopes: [], addedAt: .distantPast)
    private static let thread = ThreadKey(accountID: "audit", threadID: "t")
    private static let source = AssistantSource(accountID: "audit", threadID: "t", messageID: "m",
        partID: nil, title: "Proposal")

    private static func answer(_ text: String) -> AIResponse {
        .init(output: [.object(["type": .string("message"), "role": .string("assistant"),
            "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])],
            text: text, toolCalls: [])
    }

    private static func summary(_ text: String) throws -> AIResponse {
        let content = try AIJSON.object(["summary": .string(text), "source_ids": .array([.string(source.id)]),
            "decisions": .array([]), "open_tasks": .array([])]).jsonString()
        return answer(content)
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @MainActor private final class Fixture {
        let model: AssistantModel
        let defaults: UserDefaults
        private let domain = "AssistantProviderIntegrationTests.\(UUID().uuidString)"

        init(provider: any AIProvider, legacyModel: String? = nil) throws {
            let defaults = try #require(UserDefaults(suiteName: domain))
            self.defaults = defaults
            if let legacyModel { defaults.set(legacyModel, forKey: "assistant.selectedModel") }
            let connections = AssistantProviderConnection(chatGPT: ChatGPTConnection(store: VolatileAIConnectionStore()),
                defaults: defaults, store: VolatileAPIKeyCredentialStore())
            let account = AssistantProviderIntegrationTests.account
            let thread = AssistantProviderIntegrationTests.thread
            let source = AssistantProviderIntegrationTests.source
            model = AssistantModel(app: AppModel(), provider: provider, defaults: defaults, providerConnection: connections,
                context: {
                    AssistantContext(accounts: [account], isAccountListReady: true, currentAccountIDs: [account.id],
                        selectedThreads: [thread], accountInstances: [account.id: "instance"],
                        connectionRevision: connections.connectionRevision, canUsePlan: true)
                }, makeTools: { _ in
                    AssistantToolSession(definitions: [], execute: { _ in
                        .init(data: .object(["truncated": .bool(false), "total_messages": .number(1)]), sources: [source])
                    })
                })
            model.setAccountEnabled(account.id, enabled: true)
        }

        func close() {
            model.stop()
            defaults.removePersistentDomain(forName: domain)
        }
    }

    private actor Provider: AIProvider {
        private let supportsImages: Bool
        private var replies: [AIResponse?]
        private var holdFirstCatalogue: Bool
        private var catalogue: CheckedContinuation<[AIModel], Never>?
        private var suspended: [Int: AsyncThrowingStream<AIEvent, any Error>.Continuation] = [:]
        private(set) var requests: [AIRequest] = []

        init(replies: [AIResponse?] = [], supportsImages: Bool = true, holdFirstCatalogue: Bool = false) {
            self.replies = replies; self.supportsImages = supportsImages; self.holdFirstCatalogue = holdFirstCatalogue
        }

        func models() async throws -> [AIModel] {
            if holdFirstCatalogue {
                holdFirstCatalogue = false
                return await withCheckedContinuation { catalogue = $0 }
            }
            return [.init(id: "test-model", displayName: "Test model", supportsImages: supportsImages)]
        }

        func waitForCatalogue() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while catalogue == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(catalogue != nil)
        }

        func releaseCatalogue(_ models: [AIModel]) { catalogue?.resume(returning: models); catalogue = nil }

        nonisolated func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task { await self.start(request, continuation: continuation) }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func start(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) {
            let index = requests.count
            requests.append(request)
            guard !replies.isEmpty else {
                continuation.finish(throwing: AIProviderError.invalidRequest)
                return
            }
            if let response = replies.removeFirst() {
                continuation.yield(.completed(response)); continuation.finish()
            } else { suspended[index] = continuation }
        }

        func waitForRequests(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while requests.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(requests.count >= count)
        }

        func release(_ index: Int, response: AIResponse) {
            if let continuation = suspended.removeValue(forKey: index) {
                continuation.yield(.completed(response))
                continuation.finish()
            }
        }
    }
}
