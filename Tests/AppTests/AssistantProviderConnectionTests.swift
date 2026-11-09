import Foundation
import TernAI
import Testing
@testable import Tern

@MainActor
@Suite struct AssistantProviderConnectionTests {
    @Test func initializationIsLazyAndFailedReadCannotReplaceSavedKey() async {
        let store = ProviderMemoryStore(keys: [.openAI: "saved-key"])
        store.failLoads = true
        let connection = makeConnection(store: store)
        #expect(store.loads == 0)
        #expect(connection.selectedService == .chatGPT)
        connection.selectService(.openAI)
        await connection.restore()
        await connection.connectAPIKey("replacement-key")
        #expect(store.loads == 1)
        #expect(store.saves == 0)
        #expect(connection.needsStorageRetry)
        #expect(!connection.canUseAssistant)
        #expect(store.keys[.openAI] == "saved-key")
        store.failLoads = false
        await connection.retryStoredConnection()
        #expect(store.loads == 2)
        #expect(connection.canUseAssistant)
        #expect(!connection.needsStorageRetry)
    }

    @Test func validationStoresOnlyTheSelectedServiceAndKeepsSelectionAcrossLaunch() async throws {
        let suite = "AssistantProviderConnectionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderMemoryStore(keys: [.openAI: "openai-saved"])
        let connection = makeConnection(store: store, defaults: defaults)
        connection.selectService(.anthropic)
        await connection.connectAPIKey("  claude-key\n")
        #expect(connection.canUseAssistant)
        #expect(store.keys == [.openAI: "openai-saved", .anthropic: "claude-key"])
        #expect(!store.isDisconnected(.anthropic))
        let restarted = makeConnection(store: store, defaults: defaults)
        #expect(restarted.selectedService == .anthropic)
        #expect(!restarted.canUseAssistant)
        await restarted.restore()
        #expect(restarted.canUseAssistant)
        restarted.selectService(.deepSeek)
        await restarted.restore()
        #expect(!restarted.canUseAssistant)
    }

    @Test func switchingDuringValidationCannotInstallTheKey() async {
        let gate = ProviderConnectionGate()
        let store = ProviderMemoryStore()
        let connection = makeConnection(store: store, factory: { _, key, _ in
            ProviderConnectionStub(models: {
                _ = try await key()
                await gate.pause()
                return Self.models
            })
        })
        connection.selectService(.anthropic)
        let validation = Task { await connection.connectAPIKey("new-key") }
        await gate.waitUntilPaused()
        connection.selectService(.deepSeek)
        gate.open()
        await validation.value
        #expect(store.saves == 0)
        #expect(!connection.canUseAssistant)
        #expect(connection.errorMessage == nil)
    }

    @Test func disconnectDuringKeychainWriteClearsTheLateCredential() async throws {
        let store = ProviderMemoryStore()
        let gate = ProviderConnectionGate()
        store.beforeSave = { key in if key == "new-key" { await gate.pause() } }
        let connection = makeConnection(store: store)
        connection.selectService(.openAI)
        let validation = Task { await connection.connectAPIKey("new-key") }
        await gate.waitUntilPaused()
        let disconnect = Task { await connection.disconnectAPIKey() }
        try await waitUntil { connection.isDisconnecting }
        #expect(store.isDisconnected(.openAI))
        gate.open()
        await validation.value
        await disconnect.value
        #expect(store.keys[.openAI] == nil)
        #expect(!connection.canUseAssistant)
        #expect(store.isDisconnected(.openAI))
    }

    @Test func cancelledReplacementRestoresThePreviouslyValidatedKey() async {
        let store = ProviderMemoryStore(keys: [.openAI: "old-key"])
        let gate = ProviderConnectionGate()
        store.beforeSave = { key in if key == "new-key" { await gate.pause() } }
        let connection = makeConnection(store: store)
        connection.selectService(.openAI)
        await connection.restore()
        let validation = Task { await connection.connectAPIKey("new-key") }
        await gate.waitUntilPaused()
        connection.cancelAPIKeyConnection()
        gate.open()
        await validation.value
        #expect(store.keys[.openAI] == "old-key")
        #expect(connection.canUseAssistant)
        #expect(!store.isDisconnected(.openAI))
    }

    @Test func failedRemovalCannotReconnectAfterRelaunch() async {
        let store = ProviderMemoryStore(keys: [.deepSeek: "saved-key"])
        store.failRemovals = true
        let connection = makeConnection(store: store)
        connection.selectService(.deepSeek)
        await connection.restore()
        await connection.disconnectAPIKey()
        #expect(!connection.canUseAssistant)
        #expect(store.keys[.deepSeek] == "saved-key")
        #expect(store.isDisconnected(.deepSeek))
        let restarted = makeConnection(store: store)
        restarted.selectService(.deepSeek)
        await restarted.restore()
        #expect(!restarted.canUseAssistant)
        #expect(restarted.needsStorageRetry)
        store.failRemovals = false
        await restarted.retryStoredConnection()
        #expect(store.keys[.deepSeek] == nil)
        #expect(!restarted.needsStorageRetry)
    }

    @Test func sharedRestorationDoesNotDuplicateKeychainReads() async {
        let store = ProviderMemoryStore(keys: [.openAI: "saved-key"])
        let gate = ProviderConnectionGate()
        store.beforeLoad = { await gate.pause() }
        let connection = makeConnection(store: store)
        connection.selectService(.openAI)
        let first = Task { await connection.restore() }
        await gate.waitUntilPaused()
        #expect(connection.isRestoring)
        let second = Task { await connection.restore() }
        first.cancel()
        gate.open()
        await first.value
        await second.value
        #expect(store.loads == 1)
        #expect(connection.canUseAssistant)
    }

    @Test func streamCapturesItsServiceBeforeItsTaskStarts() async {
        let calls = ProviderConnectionCalls()
        let connection = makeConnection(store: ProviderMemoryStore(keys: [.openAI: "one", .anthropic: "two"]),
            factory: { service, _, _ in
                ProviderConnectionStub(models: { Self.models }, response: {
                    await calls.record(service)
                    return Self.response
                })
            })
        connection.selectService(.openAI)
        await connection.restore()
        let provider = connection.routedProvider()
        let stream = provider.respond(Self.request)
        // No suspension between creating the stream and changing selection.
        connection.selectService(.anthropic)
        await connection.restore()
        await #expect(throws: CancellationError.self) {
            for try await _ in stream {}
        }
        #expect(await calls.services.isEmpty)
    }

    @Test func switchingAfterCredentialReadPreventsTransportDispatch() async throws {
        let gate = ProviderConnectionGate()
        let calls = ProviderConnectionCalls()
        let connection = makeConnection(store: ProviderMemoryStore(keys: [.openAI: "one"]),
            factory: { _, key, transport in
                ProviderConnectionStub(models: {
                    _ = try await key()
                    await gate.pause()
                    let url = try #require(URL(string: "https://example.invalid/models"))
                    let response = try await transport.send(URLRequest(url: url))
                    response.cancel()
                    return Self.models
                })
            })
        connection.selectService(.openAI)
        await connection.restore()
        let transport = AIHTTPTransport { _ in
            await calls.record(.openAI)
            return AIHTTPResponse(status: 200, contentType: "application/json", body: AsyncThrowingStream { $0.finish() })
        }
        let provider = connection.routedProvider(transport: transport)
        let request = Task { try await provider.models() }
        await gate.waitUntilPaused()
        connection.selectService(.deepSeek)
        gate.open()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await calls.services.isEmpty)
    }

    @Test func staleCompletionIsDiscardedEvenWhenBackendIgnoresCancellation() async {
        let gate = ProviderConnectionGate()
        let connection = makeConnection(store: ProviderMemoryStore(keys: [.anthropic: "key"]),
            factory: { _, _, _ in
                ProviderConnectionStub(models: { Self.models }, response: {
                    await gate.pause()
                    return Self.response
                })
            })
        connection.selectService(.anthropic)
        await connection.restore()
        let stream = connection.routedProvider().respond(Self.request)
        let request = Task { () throws -> Int in
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }
        await gate.waitUntilPaused()
        connection.selectService(.chatGPT)
        gate.open()
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    @Test func restoredChatGPTConnectionUsesTheRouterWithoutWaitingForObservation() async throws {
        let oauth = try makeChatGPTConnection()
        let facade = AssistantProviderConnection(chatGPT: oauth, store: ProviderMemoryStore())
        let transport = AIHTTPTransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-chatgpt-key")
            if request.httpMethod == "GET" {
                return Self.httpResponse(#"{"models":[{"slug":"test-model","display_name":"Test model","visibility":"list"}]}"#,
                    contentType: "application/json")
            }
            let completed = """
                data: {"type":"response.completed","response":{"status":"completed","output":[{"id":"message-test","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Test response"}]}]}}


                """
            return Self.httpResponse(completed, contentType: "text/event-stream")
        }
        let provider = facade.routedProvider(transport: transport)
        await facade.restore()
        #expect(facade.canUseAssistant)
        #expect(try await provider.models().map(\.id) == ["test-model"])
        var completion: AIResponse?
        for try await event in provider.respond(Self.request) {
            if case .completed(let response) = event { completion = response }
        }
        #expect(completion?.text == "Test response")
    }

    @Test(arguments: [false, true])
    func oauthRevisionChangeRejectsAnAlreadyCreatedStream(reconnect: Bool) async throws {
        let oauth = try makeChatGPTConnection()
        let facade = AssistantProviderConnection(chatGPT: oauth, store: ProviderMemoryStore())
        await facade.restore()
        let calls = ProviderConnectionCalls()
        let provider = facade.routedProvider(transport: AIHTTPTransport { _ in
            await calls.record(.chatGPT)
            return Self.httpResponse("", contentType: "text/event-stream")
        })
        let stream = provider.respond(Self.request)
        if reconnect { await oauth.connect() } else { await oauth.disconnect() }
        await #expect(throws: CancellationError.self) { for try await _ in stream {} }
        #expect(await calls.services.isEmpty)
    }

    private func makeChatGPTConnection() throws -> ChatGPTConnection {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "registration": ["clientID": "oaiapp_tern_test", "hostID": "urn:uuid:8687c530-38cb-4d7d-ac63-0a235a03ba16",
                             "subject": "subject", "email": "test@example.invalid"],
            "account": ["subject": "subject", "email": "test@example.invalid", "name": "Test"],
            "accessToken": "synthetic-chatgpt-key", "refreshToken": "synthetic-refresh-key", "idToken": "synthetic.id.token",
            "scopes": ["openid", "resource.invoke", "chatgpt.tokens.use.direct"],
            "receivedAt": now.timeIntervalSinceReferenceDate,
            "expiresAt": now.addingTimeInterval(3600).timeIntervalSinceReferenceDate,
        ])
        let credentials = try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
        var record = ChatGPTStoredConnection()
        record.hostID = credentials.registration.hostID
        record.registration = credentials.registration
        record.credentials = credentials
        let auth = ChatGPTConnectionAuth(exchange: { _, _ in throw ChatGPTAuthError.unavailable },
            refresh: { _ in throw ChatGPTAuthError.unavailable }, verify: { _ in throw ChatGPTAuthError.unavailable },
            revoke: { _, _ in })
        return ChatGPTConnection(store: VolatileAIConnectionStore(data: try JSONEncoder().encode(record)), auth: auth,
            makeListener: { ProviderOAuthListener() }, openBrowser: { _ in false }, now: { now })
    }

    nonisolated private static func httpResponse(_ body: String, contentType: String) -> AIHTTPResponse {
        AIHTTPResponse(status: 200, contentType: contentType, body: AsyncThrowingStream {
            $0.yield(Data(body.utf8)); $0.finish()
        })
    }

    private func makeConnection(store: ProviderMemoryStore, defaults: UserDefaults? = nil,
        factory: @escaping AssistantAPIProviderFactory = { _, key, _ in
            ProviderConnectionStub(models: { _ = try await key(); return Self.models })
        }) -> AssistantProviderConnection {
        AssistantProviderConnection(chatGPT: ChatGPTConnection(store: VolatileAIConnectionStore()),
            defaults: defaults, store: store, providerFactory: factory)
    }

    nonisolated private static var models: [AIModel] { [.init(id: "test-model", displayName: "Test model")] }
    nonisolated private static var response: AIResponse { .init(output: [], text: "Test", toolCalls: []) }
    nonisolated private static var request: AIRequest {
        .init(model: "test-model", input: [.object(["role": .string("user"), "content": .string("Test")])], instructions: "")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
        throw CancellationError()
    }
}

private struct ProviderConnectionStub: AIProvider {
    let loadModels: @Sendable () async throws -> [AIModel]
    let response: @Sendable () async throws -> AIResponse
    init(models: @escaping @Sendable () async throws -> [AIModel],
         response: @escaping @Sendable () async throws -> AIResponse = { .init(output: [], text: "", toolCalls: []) }) {
        loadModels = models
        self.response = response
    }
    func models() async throws -> [AIModel] { try await loadModels() }
    func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { continuation.yield(.completed(try await response())); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor ProviderConnectionCalls {
    private(set) var services: [AIService] = []
    func record(_ service: AIService) { services.append(service) }
}

@MainActor
private final class ProviderMemoryStore: APIKeyCredentialStore {
    var keys: [AIService: String]
    private var disconnected: Set<AIService> = []
    var failLoads = false
    var failRemovals = false
    var beforeLoad: (() async -> Void)?
    var beforeSave: ((String) async -> Void)?
    private(set) var loads = 0
    private(set) var saves = 0
    init(keys: [AIService: String] = [:]) { self.keys = keys }
    func load(for service: AIService) async throws -> String? {
        loads += 1
        if failLoads { throw APIKeyStorageError() }
        if let beforeLoad { await beforeLoad() }
        return keys[service]
    }
    func save(_ key: String, for service: AIService) async throws {
        saves += 1
        if let beforeSave { await beforeSave(key) }
        keys[service] = key
    }
    func remove(for service: AIService) throws {
        if failRemovals { throw APIKeyStorageError() }
        keys[service] = nil
    }
    func isDisconnected(_ service: AIService) -> Bool { disconnected.contains(service) }
    func setDisconnected(_ value: Bool, for service: AIService) {
        if value { disconnected.insert(service) } else { disconnected.remove(service) }
    }
}

@MainActor
private final class ProviderConnectionGate {
    private var paused = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true
        arrival?.resume(); arrival = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class ProviderOAuthListener: ChatGPTCallbackListener {
    func start() throws -> URL { try #require(URL(string: "http://127.0.0.1:43210/auth/callback")) }
    func expect(state: String) {}
    func callback() throws -> URL { throw CancellationError() }
    func cancel() {}
}
