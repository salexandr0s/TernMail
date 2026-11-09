import Foundation
import Observation
import TernAI

typealias AssistantAPIProviderFactory = @Sendable (
    AIService, @escaping @Sendable () async throws -> String, AIHTTPTransport
) -> any AIProvider

/// Selects an authentication route without altering the ChatGPT OAuth record.
@MainActor
@Observable
final class AssistantProviderConnection {
    let chatGPT: ChatGPTConnection
    let claudeCLI: ClaudeCLIConnection
    private(set) var selectedService: AIService
    private var revision = 0 { didSet { publishRouteState() } }
    private var keys: [AIService: String] = [:]
    private var loaded: Set<AIService> = []
    private var disconnected: Set<AIService>
    private var restoring: Set<AIService> = []
    private var failedReads: Set<AIService> = []
    private var failedRemovals: Set<AIService> = []
    private var errors: [AIService: String] = [:]
    private var connectingService: AIService?
    private var disconnectingService: AIService?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let store: any APIKeyCredentialStore
    @ObservationIgnored private let providerFactory: AssistantAPIProviderFactory
    @ObservationIgnored private let validationTransport: AIHTTPTransport
    @ObservationIgnored private let routeState: AssistantRouteState
    @ObservationIgnored private var loadTasks: [AIService: Task<Void, any Error>] = [:]
    @ObservationIgnored private var credentialTask: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var disconnectRevisions: [AIService: Int] = [:]

    static let selectionKey = "assistant.selectedService"

    init(chatGPT: ChatGPTConnection, defaults: UserDefaults? = nil, claudeCLI: ClaudeCLIConnection? = nil,
         store: (any APIKeyCredentialStore)? = nil,
         providerFactory: @escaping AssistantAPIProviderFactory = AssistantProviderConnection.makeAPIProvider,
         validationTransport: AIHTTPTransport = .live) {
        self.chatGPT = chatGPT
        let claude = claudeCLI ?? ClaudeCLIConnection(defaults: defaults)
        self.claudeCLI = claude
        self.defaults = defaults
        self.providerFactory = providerFactory
        self.validationTransport = validationTransport
        let store = store ?? Self.defaultStore()
        self.store = store
        let selection = defaults?.string(forKey: Self.selectionKey).flatMap(AIService.init(rawValue:)) ?? .chatGPT
        selectedService = selection
        disconnected = Set(AIService.allCases.filter { $0.usesAPIKey && store.isDisconnected($0) })
        routeState = AssistantRouteState(service: selection, revision: chatGPT.connectionRevision + claude.connectionRevision)
        observeConnectionRevisions()
    }

    var connectionRevision: Int { revision + chatGPT.connectionRevision + claudeCLI.connectionRevision }
    var canUseAssistant: Bool {
        if selectedService == .chatGPT { return chatGPT.canUsePlan }
        if selectedService == .claudeCode { return claudeCLI.canUseAssistant }
        return loaded.contains(selectedService) && keys[selectedService] != nil
            && !disconnected.contains(selectedService) && !isConnecting && !isDisconnecting
    }
    var isRestoring: Bool {
        if selectedService == .claudeCode { return claudeCLI.isRestoring }
        return selectedService == .chatGPT ? chatGPT.isRestoring : restoring.contains(selectedService)
    }
    var isConnecting: Bool {
        if selectedService == .claudeCode { return claudeCLI.isConnecting }
        return selectedService == .chatGPT ? chatGPT.isConnecting : connectingService == selectedService
    }
    var isDisconnecting: Bool {
        if selectedService == .claudeCode { return claudeCLI.isDisconnecting }
        return selectedService == .chatGPT ? chatGPT.isDisconnecting : disconnectingService == selectedService
    }
    var needsStorageRetry: Bool {
        selectedService == .chatGPT ? chatGPT.needsStorageRetry
            : failedReads.contains(selectedService) || failedRemovals.contains(selectedService)
    }
    var errorMessage: String? {
        if selectedService == .claudeCode { return claudeCLI.errorMessage }
        return selectedService == .chatGPT ? chatGPT.errorMessage : errors[selectedService]
    }
    var hasAPIKey: Bool { selectedService.usesAPIKey && keys[selectedService] != nil && !disconnected.contains(selectedService) }

    func selectService(_ service: AIService) {
        guard service != selectedService else { return }
        cancelAPIKeyConnection()
        if selectedService == .claudeCode { claudeCLI.cancelWork() }
        selectedService = service
        defaults?.set(service.rawValue, forKey: Self.selectionKey)
        revision += 1
    }

    func restore() async {
        if selectedService == .chatGPT { await chatGPT.recoverPendingConnection(); return }
        if selectedService == .claudeCode { await claudeCLI.restore(); return }
        let service = selectedService
        try? await ensureLoaded(service)
        if selectedService == service, disconnected.contains(service), keys[service] != nil,
           !failedRemovals.contains(service), !isConnecting, !isDisconnecting { await disconnectAPIKey() }
    }

    func retryStoredConnection() async {
        if selectedService == .chatGPT { await chatGPT.retryStoredConnection(); return }
        if selectedService == .claudeCode { await claudeCLI.checkAvailability(); return }
        guard !isConnecting, !isDisconnecting else { return }
        let service = selectedService
        try? await ensureLoaded(service, retry: true)
        if selectedService == service, disconnected.contains(service),
           keys[service] != nil || failedRemovals.contains(service) {
            await disconnectAPIKey()
        }
    }

    func connectAPIKey(_ input: String) async {
        let service = selectedService
        guard service.usesAPIKey, connectingService != service, disconnectingService != service else { return }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validKey(key) else { errors[service] = AIProviderError.apiKeyRequired.localizedDescription; return }
        let previous = credentialTask
        previous?.cancel()
        let id = UUID()
        operationID = id
        connectingService = service
        errors[service] = nil
        revision += 1
        let task = Task { [self] in
            if let previous { await previous.value }
            defer { finishOperation(id) }
            do {
                try checkOperation(id, service: service)
                try await ensureLoaded(service)
                try checkOperation(id, service: service)
                let expected = connectionRevision
                let transport = AIHTTPTransport { [weak self, validationTransport] request in
                    try await self?.checkValidation(id, service: service, revision: expected)
                    guard self != nil else { throw CancellationError() }
                    return try await validationTransport.send(request)
                }
                let models = try await providerFactory(service, { key }, transport).models()
                try checkOperation(id, service: service)
                guard !models.isEmpty else { throw AIProviderError.invalidResponse }
                try await install(key, service: service, operation: id)
            } catch {
                if operationID == id, !(error is CancellationError) { errors[service] = Self.safeMessage(error) }
            }
        }
        credentialTask = task
        await withTaskCancellationHandler { await task.value } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operationID == id else { return }
                self?.cancelAPIKeyConnection()
            }
        }
    }

    func cancelAPIKeyConnection() {
        guard connectingService != nil else { return }
        credentialTask?.cancel()
        connectingService = nil
        revision += 1
    }

    func disconnectAPIKey() async {
        let service = selectedService
        guard service.usesAPIKey, disconnectingService != service else { return }
        let previous = credentialTask
        if connectingService != nil { previous?.cancel() }
        let id = UUID()
        operationID = id
        connectingService = nil
        disconnectingService = service
        disconnectRevisions[service, default: 0] += 1
        setDisconnected(true, service: service)
        revision += 1
        errors[service] = nil
        let task = Task { [self] in
            if let previous { await previous.value }
            defer { finishOperation(id) }
            do {
                // Preserve unread credentials when the Keychain denies access.
                try await ensureLoaded(service, retry: true)
                try await store.remove(for: service)
                keys[service] = nil
                failedRemovals.remove(service)
                errors[service] = nil
                revision += 1
            } catch {
                failedRemovals.insert(service)
                errors[service] = "Disconnected. Allow Keychain access to remove the saved API key."
            }
        }
        credentialTask = task
        await task.value
    }

    func routedProvider(transport: AIHTTPTransport = .live,
                        isAuthorized: @escaping @Sendable () async -> Bool = { true }) -> any AIProvider {
        AssistantRoutingProvider(state: routeState) { [weak self] snapshot in
            guard let self else { throw CancellationError() }
            return try await self.route(snapshot, transport: transport, isAuthorized: isAuthorized)
        }
    }

    private func route(_ snapshot: AssistantRouteSnapshot, transport: AIHTTPTransport,
                       isAuthorized: @escaping @Sendable () async -> Bool) throws -> AssistantProviderRoute {
        let service = snapshot.service
        let expected = snapshot.revision
        guard routeState.matches(snapshot), matches(service, revision: expected) else { throw CancellationError() }
        let check: @Sendable () async throws -> Void = { [weak self, routeState] in
            try Task.checkCancellation()
            guard routeState.matches(snapshot), await isAuthorized(), let self,
                  await self.matches(service, revision: expected) else { throw CancellationError() }
            guard routeState.matches(snapshot) else { throw CancellationError() }
            try Task.checkCancellation()
        }
        let credential: @Sendable () async throws -> String = { [weak self] in
            try await check()
            guard let self else { throw CancellationError() }
            let key = try await self.credential(service: service)
            try await check()
            return key
        }
        let guarded = AIHTTPTransport { request in
            try await check()
            let response = try await transport.send(request)
            do { try await check(); return response }
            catch { response.cancel(); throw error }
        }
        let provider: any AIProvider
        if service == .claudeCode {
            provider = ClaudeCLIProvider(transport: claudeCLI.transport(isAuthorized: check))
        } else if service == .chatGPT { provider = ChatGPTProvider(accessToken: credential, transport: guarded) }
        else { provider = providerFactory(service, credential, guarded) }
        return AssistantProviderRoute(provider: provider, check: check)
    }

    private func credential(service: AIService) async throws -> String {
        if service == .chatGPT { return try await chatGPT.accessToken() }
        guard loaded.contains(service), !disconnected.contains(service),
              connectingService != service, disconnectingService != service, let key = keys[service] else {
            throw AIProviderError.apiKeyRequired
        }
        return key
    }

    private func matches(_ service: AIService, revision: Int) -> Bool {
        selectedService == service && connectionRevision == revision
    }

    private func publishRouteState() {
        routeState.publish(service: selectedService, revision: connectionRevision)
    }

    private func observeConnectionRevisions() {
        withObservationTracking {
            _ = chatGPT.connectionRevision
            _ = claudeCLI.connectionRevision
        } onChange: { [weak self, routeState] in
            // Observation fires before the property changes. Reject new captures
            // until the actor has finished that mutation and rearmed observation.
            routeState.invalidate()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeConnectionRevisions()
                routeState.publish(service: self.selectedService, revision: self.connectionRevision, finishObservation: true)
            }
        }
    }

    private func ensureLoaded(_ service: AIService, retry: Bool = false) async throws {
        if loaded.contains(service) { return }
        if let task = loadTasks[service] { return try await task.value }
        guard retry || !failedReads.contains(service) else { throw APIKeyStorageError() }
        restoring.insert(service)
        let task = Task<Void, any Error> { [self] in
            defer { restoring.remove(service); loadTasks[service] = nil }
            do {
                let key = try await store.load(for: service)
                guard key.map(Self.validKey) ?? true else { throw APIKeyStorageError() }
                keys[service] = key
                loaded.insert(service)
                failedReads.remove(service)
                errors[service] = nil
                revision += 1
            } catch {
                failedReads.insert(service)
                errors[service] = APIKeyStorageError().localizedDescription
                throw APIKeyStorageError()
            }
        }
        loadTasks[service] = task
        try await task.value
    }

    private func install(_ key: String, service: AIService, operation id: UUID) async throws {
        let oldKey = keys[service]
        let wasDisconnected = disconnected.contains(service)
        let disconnectRevision = disconnectRevisions[service, default: 0]
        setDisconnected(true, service: service)
        do {
            try await store.save(key, for: service)
            try checkOperation(id, service: service)
            keys[service] = key
            setDisconnected(false, service: service)
            failedRemovals.remove(service)
            revision += 1
        } catch {
            // A cancelled validation can outlive an uncancellable Keychain write.
            // Finish rollback before the next credential operation starts.
            do {
                if let oldKey { try await store.save(oldKey, for: service) }
                else { try await store.remove(for: service) }
                if disconnectRevisions[service, default: 0] == disconnectRevision {
                    setDisconnected(wasDisconnected, service: service)
                }
            } catch {
                setDisconnected(true, service: service)
                failedRemovals.insert(service)
                errors[service] = "Allow Keychain access to repair the saved API connection, then connect again."
            }
            throw error
        }
    }

    private func checkOperation(_ id: UUID, service: AIService) throws {
        try Task.checkCancellation()
        guard operationID == id, selectedService == service else { throw CancellationError() }
    }

    private func checkValidation(_ id: UUID, service: AIService, revision: Int) throws {
        try checkOperation(id, service: service)
        guard connectionRevision == revision else { throw CancellationError() }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        connectingService = nil
        disconnectingService = nil
        credentialTask = nil
        operationID = nil
        revision += 1
    }

    private func setDisconnected(_ value: Bool, service: AIService) {
        store.setDisconnected(value, for: service)
        if value { disconnected.insert(service) } else { disconnected.remove(service) }
    }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 16_384 && key.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }

    private static func safeMessage(_ error: any Error) -> String {
        if let error = error as? AIProviderError { return error.localizedDescription }
        if error is APIKeyStorageError { return APIKeyStorageError().localizedDescription }
        return "Tern could not validate this API key. Check the key and try again."
    }

    nonisolated private static func makeAPIProvider(_ service: AIService,
        key: @escaping @Sendable () async throws -> String, transport: AIHTTPTransport) -> any AIProvider {
        if service == .anthropic { return AnthropicProvider(apiKey: key, transport: transport) }
        return ResponsesAPIProvider(service: service, apiKey: key, transport: transport)
    }

    private static func defaultStore() -> any APIKeyCredentialStore {
        if LaunchMode.current.isIsolated { return VolatileAPIKeyCredentialStore() }
        return KeychainAPIKeyCredentialStore()
    }
}
