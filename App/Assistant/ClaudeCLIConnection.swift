import Foundation
import Observation
import TernAI

/// Tern's opt-in is independent of the user's global Claude Code login.
@MainActor
@Observable
final class ClaudeCLIConnection {
    private(set) var status: ClaudeCLIStatus?
    private(set) var isConnecting = false
    private(set) var isRestoring = false
    private(set) var isDisconnecting = false
    private(set) var isSubmittingCode = false
    private(set) var signInURL: URL?
    private(set) var errorMessage: String?
    private(set) var connectionRevision = 0
    private var enabled: Bool
    private var identity: ClaudeCLIIdentity?
    @ObservationIgnored private let client: ClaudeCLIClient
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loginRequestID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var restoreID: UUID?
    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    /// The last account check made before a request. It counts only for the
    /// generation that made it, so connecting, disconnecting, switching
    /// providers and an account change all discard it.
    @ObservationIgnored private var statusCheck: (generation: Int, at: ContinuousClock.Instant)?

    static let enabledKey = "assistant.claudeCLI.enabled"
    static let identityKey = "assistant.claudeCLI.identity"
    /// Requests this soon after a check skip their own. The helper still checks
    /// the account before and after every request.
    static let statusLifetime: Duration = .seconds(30)

    init(client: ClaudeCLIClient? = nil, defaults: UserDefaults? = nil, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.client = client ?? Self.defaultClient()
        self.defaults = defaults
        self.now = now
        let savedIdentity = defaults?.data(forKey: Self.identityKey).flatMap { try? JSONDecoder().decode(ClaudeCLIIdentity.self, from: $0) }
        identity = savedIdentity
        enabled = defaults?.bool(forKey: Self.enabledKey) == true && savedIdentity != nil
    }

    var isInstalled: Bool { status?.available == true }
    var isConnected: Bool { canUseAssistant }
    var canUseAssistant: Bool {
        enabled && !isConnecting && !isDisconnecting && status?.loggedIn == true
            && identity != nil && status.flatMap { try? ClaudeCLIIdentity(status: $0) } == identity
    }
    var canSubmitLoginCode: Bool { isConnecting && loginRequestID != nil && signInURL != nil && !isSubmittingCode }
    var authenticationLabel: String {
        guard status?.authMethod == "claude.ai" else {
            return ["api_key", "console", "apiKey", "console.anthropic.com"].contains(status?.authMethod ?? "")
                ? "Claude Console · API billing" : "Claude Code account"
        }
        switch status?.subscriptionType?.lowercased() {
        case "max": return "Claude Max subscription"
        case "pro": return "Claude Pro subscription"
        case "team": return "Claude Team subscription"
        case "enterprise": return "Claude Enterprise subscription"
        default: return "Claude subscription"
        }
    }

    func restore() async {
        guard !isConnecting else { return }
        if let restoreTask { await restoreTask.value; return }
        guard !hasRestored else { return }
        await checkAvailability()
    }

    func checkAvailability() async {
        guard !isConnecting else { return }
        if let restoreTask { await restoreTask.value; return }
        let expected = generation
        let id = UUID()
        restoreID = id
        isRestoring = true
        let restoration = Task { [self] in
            defer {
                if restoreID == id { isRestoring = false; restoreTask = nil; restoreID = nil }
            }
            do {
                let value = try await client.status()
                guard generation == expected, !Task.isCancelled else { return }
                hasRestored = true
                updateStatus(value)
                if enabled { try verifyIdentity(value) }
                else { errorMessage = nil }
            } catch {
                guard generation == expected, !(error is CancellationError) else { return }
                errorMessage = Self.safeMessage(error)
            }
        }
        restoreTask = restoration
        await restoration.value
    }

    func connect() async { await connect(forceLogin: false) }
    func signIn() async { await connect(forceLogin: true) }

    private func connect(forceLogin: Bool) async {
        guard !isConnecting, !isDisconnecting else { return }
        generation += 1
        let expected = generation
        restoreTask?.cancel()
        restoreTask = nil; restoreID = nil
        isRestoring = false
        isConnecting = true
        signInURL = nil
        errorMessage = nil
        connectionRevision += 1
        let connection = Task { [self] in
            defer {
                if generation == expected {
                    isConnecting = false; signInURL = nil; loginRequestID = nil; isSubmittingCode = false
                    task = nil; connectionRevision += 1
                }
            }
            do {
                var value = try await client.status()
                try ensureCurrent(expected)
                guard value.available else { updateStatus(value); throw ClaudeCLIConnectionError.notInstalled }
                if forceLogin || !value.loggedIn {
                    let id = UUID().uuidString
                    loginRequestID = id
                    try await client.login(id) { [weak self] event in
                        Task { @MainActor [weak self] in self?.loginEvent(event, requestID: id, generation: expected) }
                    }
                    try ensureCurrent(expected)
                    value = try await client.status()
                }
                try ensureCurrent(expected)
                guard value.loggedIn else { throw ClaudeCLIConnectionError.signInRequired }
                let accepted = try ClaudeCLIIdentity(status: value)
                let data = try JSONEncoder().encode(accepted)
                identity = accepted
                defaults?.set(data, forKey: Self.identityKey)
                enabled = true
                defaults?.set(true, forKey: Self.enabledKey)
                hasRestored = true
                updateStatus(value)
            } catch {
                if generation == expected, !(error is CancellationError) { errorMessage = Self.safeMessage(error) }
            }
        }
        task = connection
        await withTaskCancellationHandler { await connection.value } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == expected else { return }
                self?.cancelSignIn()
            }
        }
    }

    func submitLoginCode(_ input: String) async {
        guard canSubmitLoginCode, let requestID = loginRequestID else { return }
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.utf8.count <= 8192, code.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }) else {
            errorMessage = ClaudeCLIConnectionError.invalidCode.localizedDescription; return
        }
        let expected = generation
        isSubmittingCode = true
        defer { if generation == expected { isSubmittingCode = false } }
        do { try await client.submitLoginCode(code, requestID) }
        catch {
            if generation == expected, !(error is CancellationError) { errorMessage = Self.safeMessage(error) }
        }
    }

    func cancelSignIn() {
        guard isConnecting else { return }
        generation += 1
        if let loginRequestID { client.cancel(loginRequestID) }
        task?.cancel(); task = nil
        loginRequestID = nil; signInURL = nil
        isConnecting = false; isSubmittingCode = false
        connectionRevision += 1
    }

    /// Changing providers cancels owned work while retaining the user's opt-in.
    func cancelWork() {
        cancelSignIn()
        generation += 1
        restoreTask?.cancel(); restoreTask = nil; restoreID = nil
        isRestoring = false
        client.cancelAll()
        connectionRevision += 1
    }

    func disconnect() async {
        isDisconnecting = true
        generation += 1
        enabled = false
        defaults?.set(false, forKey: Self.enabledKey)
        identity = nil
        defaults?.removeObject(forKey: Self.identityKey)
        cancelWork()
        errorMessage = nil
        connectionRevision += 1
        isDisconnecting = false
    }

    func transport(isAuthorized: @escaping @Sendable () async throws -> Void = {}) -> ClaudeCLITransport {
        let expected = generation
        let expectedIdentity = identity
        return ClaudeCLITransport { [weak self] request in
            AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
                let task = Task { @MainActor [weak self] in
                    do {
                        guard let self, let expectedIdentity else { throw AIProviderError.signInRequired }
                        try await isAuthorized()
                        try self.ensureCurrent(expected)
                        guard self.canUseAssistant else { throw AIProviderError.signInRequired }
                        if !self.checkedRecently(expected) {
                            let checkedAt = self.now()
                            let value = try await self.client.status()
                            try await isAuthorized()
                            try self.ensureCurrent(expected)
                            try self.verifyIdentity(value)
                            self.statusCheck = (expected, checkedAt)
                        }
                        guard self.identity == expectedIdentity else { throw ClaudeCLIConnectionError.accountChanged }
                        // This synchronous call registers the request before a
                        // provider switch can cancel this connection's work.
                        let stream = self.client.run(request, expectedIdentity)
                        for try await line in stream {
                            try await isAuthorized()
                            try self.ensureCurrent(expected)
                            switch continuation.yield(line) {
                            case .enqueued: break
                            case .dropped: throw AIProviderError.responseLimit
                            case .terminated: throw CancellationError()
                            @unknown default: throw ClaudeCLIConnectionError.invalidResponse
                            }
                        }
                        try await isAuthorized()
                        try self.ensureCurrent(expected)
                        continuation.finish()
                    } catch {
                        if let self, self.generation == expected, self.enabled,
                           let failure = error as? ClaudeCLIConnectionError, case .accountChanged = failure {
                            self.invalidateAcceptedAccount()
                        }
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func checkedRecently(_ expected: Int) -> Bool {
        guard let statusCheck, statusCheck.generation == expected else { return false }
        return statusCheck.at.duration(to: now()) < Self.statusLifetime
    }

    private func verifyIdentity(_ value: ClaudeCLIStatus) throws {
        guard enabled, value.available, value.loggedIn,
              (try? ClaudeCLIIdentity(status: value)) == identity else {
            updateStatus(value)
            invalidateAcceptedAccount()
            throw ClaudeCLIConnectionError.accountChanged
        }
    }

    private func invalidateAcceptedAccount() {
        generation += 1
        enabled = false
        defaults?.set(false, forKey: Self.enabledKey)
        errorMessage = ClaudeCLIConnectionError.accountChanged.localizedDescription
        connectionRevision += 1
        client.cancelAll()
    }

    private func updateStatus(_ value: ClaudeCLIStatus) {
        let changed = status?.accountFingerprint != value.accountFingerprint || status?.authMethod != value.authMethod
            || status?.subscriptionType != value.subscriptionType || status?.loggedIn != value.loggedIn
            || status?.available != value.available
        status = value
        if changed { connectionRevision += 1 }
    }

    private func loginEvent(_ data: Data, requestID: String, generation expected: Int) {
        guard expected == generation, loginRequestID == requestID, data.count <= 16_384,
              let value = try? AIJSON.decode(data), value["type"]?.stringValue == "auth_url",
              let address = value["url"]?.stringValue, let url = URL(string: address),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host, ["claude.ai", "console.anthropic.com", "platform.claude.com", "platform.anthropic.com"].contains(host) else { return }
        // The official CLI opens the browser. Keep its URL for the manual link
        // without opening the same sign-in page a second time.
        signInURL = url
    }

    private func ensureCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }

    private static func safeMessage(_ error: any Error) -> String {
        if let error = error as? ClaudeCLIConnectionError { return error.localizedDescription }
        if let error = error as? AIProviderError { return error.localizedDescription }
        return ClaudeCLIConnectionError.helperUnavailable.localizedDescription
    }

    private static func defaultClient() -> ClaudeCLIClient {
        let mode = LaunchMode.current
        guard mode.isIsolated else { return .live }
        #if TERN_TEST_SUPPORT
        // An explicit standalone audit may use the official CLI while mail stays
        // synthetic. Hosted tests always inject their own client instead.
        if mode.host == .audit, mode.audit.liveClaude { return .live }
        #endif
        return .unavailable
    }
}
