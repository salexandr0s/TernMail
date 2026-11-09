import Foundation
import Synchronization
import Testing
import TernAI
@testable import Tern

@MainActor
@Suite struct ClaudeCLIConnectionTests {
    @Test func restoreRequiresExplicitOptInEvenWithAnExistingCLILogin() async {
        let fixture = CLITestClient()
        let connection = ClaudeCLIConnection(client: fixture.client)
        await connection.restore()
        #expect(connection.isInstalled)
        #expect(!connection.canUseAssistant)
        #expect(fixture.logins == 0)
        await connection.connect()
        #expect(connection.canUseAssistant)
        #expect(fixture.logins == 0)
        #expect(connection.authenticationLabel == "Claude Max subscription")
    }

    @Test func savedOptInRestoresButDisconnectDoesNotRestoreOrLogOutTheCLI() async throws {
        let suite = "ClaudeCLIConnectionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CLITestClient()
        let connection = ClaudeCLIConnection(client: fixture.client, defaults: defaults)
        await connection.connect()
        let restored = ClaudeCLIConnection(client: fixture.client, defaults: defaults)
        await restored.restore()
        #expect(restored.canUseAssistant)
        await restored.disconnect()
        #expect(!defaults.bool(forKey: ClaudeCLIConnection.enabledKey))
        #expect(defaults.data(forKey: ClaudeCLIConnection.identityKey) == nil)
        let disconnected = ClaudeCLIConnection(client: fixture.client, defaults: defaults)
        await disconnected.restore()
        #expect(!disconnected.canUseAssistant)
        #expect(fixture.value.loggedIn)
        #expect(fixture.logins == 0)
    }

    @Test func cancellingSignInCannotAdoptALateSuccessfulLogin() async {
        let fixture = CLITestClient()
        fixture.value = .init(available: true)
        let gate = CLITestGate()
        fixture.loginGate = gate
        let connection = ClaudeCLIConnection(client: fixture.client)
        let login = Task { await connection.connect() }
        await gate.arrived()
        let requestID = fixture.loginID
        connection.cancelSignIn()
        fixture.value = Self.connected()
        gate.open()
        await login.value
        #expect(!connection.canUseAssistant)
        #expect(!connection.isConnecting)
        #expect(connection.signInURL == nil)
        #expect(fixture.cancellations.ids.contains(requestID ?? ""))
    }

    @Test func changedSavedAccountFinishesRestorationAndAllowsExplicitReconnect() async throws {
        let suite = "ClaudeCLIConnectionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CLITestClient()
        await ClaudeCLIConnection(client: fixture.client, defaults: defaults).connect()
        fixture.value = Self.connected(fingerprint: String(repeating: "b", count: 64))
        let restored = ClaudeCLIConnection(client: fixture.client, defaults: defaults)
        await restored.restore()
        #expect(!restored.canUseAssistant)
        #expect(!restored.isRestoring)
        #expect(!defaults.bool(forKey: ClaudeCLIConnection.enabledKey))
        await restored.connect()
        #expect(restored.canUseAssistant)
    }

    @Test func accountChangeBeforeDispatchRequiresAnotherExplicitConnection() async throws {
        let fixture = CLITestClient()
        let connection = ClaudeCLIConnection(client: fixture.client)
        await connection.connect()
        fixture.value = Self.connected(fingerprint: String(repeating: "b", count: 64))
        let transport = connection.transport()
        await #expect(throws: ClaudeCLIConnectionError.self) {
            for try await _ in transport.run(Self.request) {}
        }
        #expect(!connection.canUseAssistant)
        #expect(fixture.runs.count == 0)
        #expect(connection.errorMessage?.contains("account or billing method changed") == true)
        await connection.connect()
        #expect(connection.canUseAssistant)
    }

    @Test func consoleBillingRequiresExplicitAcceptanceAndCannotChangeSilently() async {
        let fixture = CLITestClient()
        fixture.value = Self.connected(method: "api_key", subscription: nil)
        let connection = ClaudeCLIConnection(client: fixture.client)
        await connection.connect()
        #expect(connection.canUseAssistant)
        #expect(connection.authenticationLabel == "Claude Console · API billing")
        fixture.value = Self.connected(method: "claude.ai", subscription: "max")
        await #expect(throws: ClaudeCLIConnectionError.self) {
            for try await _ in connection.transport().run(Self.request) {}
        }
        #expect(!connection.canUseAssistant)
        #expect(fixture.runs.count == 0)
    }

    @Test func disconnectDuringStatusCheckPreventsInference() async {
        let fixture = CLITestClient()
        let connection = ClaudeCLIConnection(client: fixture.client)
        await connection.connect()
        let gate = CLITestGate()
        fixture.statusGate = gate
        let request = Task { () throws -> Void in
            for try await _ in connection.transport().run(Self.request) {}
        }
        await gate.arrived()
        await connection.disconnect()
        gate.open()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(fixture.runs.count == 0)
    }

    @Test func providerSwitchRejectsAnAlreadyCreatedClaudeStream() async {
        let fixture = CLITestClient()
        let claude = ClaudeCLIConnection(client: fixture.client)
        let facade = AssistantProviderConnection(chatGPT: ChatGPTConnection(store: VolatileAIConnectionStore()), claudeCLI: claude)
        facade.selectService(.claudeCode)
        await claude.connect()
        // A facade refresh synchronizes its observed connection before use.
        await facade.restore()
        let stream = facade.routedProvider().respond(.init(model: "sonnet",
            input: [.object(["role": .string("user"), "content": .string("Test")])], instructions: "Test"))
        facade.selectService(.openAI)
        await #expect(throws: CancellationError.self) { for try await _ in stream {} }
        #expect(fixture.runs.count == 0)
        #expect(claude.canUseAssistant)
    }

    @Test func loginURLAndCodeStayBoundToTheActiveLogin() async throws {
        let fixture = CLITestClient()
        fixture.value = .init(available: true)
        let gate = CLITestGate()
        fixture.loginGate = gate
        let connection = ClaudeCLIConnection(client: fixture.client)
        let login = Task { await connection.connect() }
        await gate.arrived()
        let requestID = try #require(fixture.loginID)
        fixture.loginEvent?(Data(#"{"type":"auth_url","url":"https://example.invalid/capture"}"#.utf8))
        for _ in 0..<5 { await Task.yield() }
        #expect(connection.signInURL == nil)
        fixture.loginEvent?(Data(#"{"type":"auth_url","url":"https://claude.ai/oauth/authorize?state=synthetic"}"#.utf8))
        try await waitUntil { connection.canSubmitLoginCode }
        #expect(connection.signInURL?.absoluteString == "https://claude.ai/oauth/authorize?state=synthetic")
        await connection.submitLoginCode(" synthetic-code#state ")
        #expect(fixture.codes == [.init(code: "synthetic-code#state", requestID: requestID)])
        connection.cancelSignIn()
        await connection.submitLoginCode("late-code")
        #expect(fixture.codes.count == 1)
        gate.open()
        await login.value
        #expect(connection.signInURL == nil)
        #expect(!connection.canSubmitLoginCode)
    }

    @Test func helperFailureCanBeRetriedWithoutLosingOptIn() async throws {
        let suite = "ClaudeCLIConnectionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CLITestClient()
        await ClaudeCLIConnection(client: fixture.client, defaults: defaults).connect()
        fixture.failStatus = true
        let restored = ClaudeCLIConnection(client: fixture.client, defaults: defaults)
        await restored.restore()
        #expect(!restored.canUseAssistant)
        #expect(defaults.bool(forKey: ClaudeCLIConnection.enabledKey))
        fixture.failStatus = false
        await restored.checkAvailability()
        #expect(restored.canUseAssistant)
    }

    @Test func helperAccountChangeAtDispatchInvalidatesTheLocalConnection() async {
        let fixture = CLITestClient()
        var client = fixture.client
        client.run = { _, _ in AsyncThrowingStream { $0.finish(throwing: ClaudeCLIConnectionError.accountChanged) } }
        let connection = ClaudeCLIConnection(client: client)
        await connection.connect()
        let revision = connection.connectionRevision
        await #expect(throws: ClaudeCLIConnectionError.self) {
            for try await _ in connection.transport().run(Self.request) {}
        }
        #expect(!connection.canUseAssistant)
        #expect(connection.connectionRevision > revision)
    }

    @Test func recentAccountCheckCoversRequestsUntilItExpires() async throws {
        let fixture = CLITestClient()
        let clock = CLITestClock()
        let connection = ClaudeCLIConnection(client: fixture.client, now: { clock.now })
        await connection.connect()
        let checks = fixture.statusCalls
        for _ in 0..<3 { try await Self.send(connection) }
        #expect(fixture.statusCalls == checks + 1)
        #expect(fixture.runs.count == 3)
        clock.advance(by: ClaudeCLIConnection.statusLifetime)
        try await Self.send(connection)
        #expect(fixture.statusCalls == checks + 2)
    }

    @Test func connectionChangesDiscardTheRecentAccountCheck() async throws {
        let fixture = CLITestClient()
        let accountChanged = Mutex(false)
        var client = fixture.client
        client.run = { [runs = fixture.runs] _, _ in
            runs.record()
            let changed = accountChanged.withLock { $0 }
            return AsyncThrowingStream { continuation in
                if changed { continuation.finish(throwing: ClaudeCLIConnectionError.accountChanged) } else { continuation.finish() }
            }
        }
        // The clock never advances, so only a change can make a request check again.
        let clock = CLITestClock()
        let connection = ClaudeCLIConnection(client: client, now: { clock.now })
        await connection.connect()
        try await Self.send(connection)
        await connection.connect()
        var checks = fixture.statusCalls
        try await Self.send(connection)
        #expect(fixture.statusCalls == checks + 1)
        connection.cancelWork()
        checks = fixture.statusCalls
        try await Self.send(connection)
        #expect(fixture.statusCalls == checks + 1)
        // The helper's own check still stops a request that reuses a recent check.
        accountChanged.withLock { $0 = true }
        await #expect(throws: ClaudeCLIConnectionError.self) { try await Self.send(connection) }
        #expect(!connection.canUseAssistant)
    }

    @Test func busyHelperReportsItsOwnError() {
        #expect(ClaudeCLIConnectionError.helper("busy") as? AIProviderError == .busy)
    }

    private static func send(_ connection: ClaudeCLIConnection) async throws {
        for try await _ in connection.transport().run(request) {}
    }

    nonisolated static func connected(fingerprint: String = String(repeating: "a", count: 64),
        method: String = "claude.ai", subscription: String? = "max") -> ClaudeCLIStatus {
        .init(available: true, version: "2.1.128", loggedIn: true, authMethod: method,
            subscriptionType: subscription, accountFingerprint: fingerprint)
    }
    nonisolated private static var request: ClaudeCLIRequest {
        .init(model: "sonnet", systemPrompt: ClaudeCLIRequest.framingInstructions,
            message: .object(["type": .string("user"), "message": .object(["role": .string("user"),
                "content": .string("Test")])]), outputSchema: nil)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        throw CancellationError()
    }
}

@MainActor
private final class CLITestClient {
    struct Code: Equatable { let code: String; let requestID: String }
    var value = ClaudeCLIConnectionTests.connected()
    var failStatus = false
    var statusGate: CLITestGate?
    var loginGate: CLITestGate?
    var loginID: String?
    var loginEvent: (@Sendable (Data) -> Void)?
    var logins = 0
    var statusCalls = 0
    var codes: [Code] = []
    let runs = CLITestRunCounter()
    let cancellations = CLITestCancellationCounter()

    var client: ClaudeCLIClient {
        ClaudeCLIClient(status: { [self] in try await status() },
            login: { [self] id, event in await login(id, event: event) },
            submitLoginCode: { [self] code, id in await recordCode(code, id: id) },
            run: { [runs] _, _ in
                runs.record()
                return AsyncThrowingStream { $0.finish() }
            }, cancel: { [cancellations] id in cancellations.record(id) },
            cancelAll: { [cancellations] in cancellations.record("all") })
    }
    private func status() async throws -> ClaudeCLIStatus {
        statusCalls += 1
        if let statusGate { await statusGate.pause() }
        if failStatus { throw ClaudeCLIConnectionError.helperUnavailable }
        return value
    }
    private func login(_ id: String, event: @escaping @Sendable (Data) -> Void) async {
        logins += 1; loginID = id; loginEvent = event
        if let loginGate { await loginGate.pause() }
    }
    private func recordCode(_ code: String, id: String) { codes.append(.init(code: code, requestID: id)) }
}

private final class CLITestRunCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func record() { value.withLock { $0 += 1 } }
}
private final class CLITestCancellationCounter: Sendable {
    private let value = Mutex<[String]>([])
    var ids: [String] { value.withLock { $0 } }
    func record(_ id: String) { value.withLock { $0.append(id) } }
}
@MainActor
private final class CLITestClock {
    private(set) var now = ContinuousClock.now
    func advance(by duration: Duration) { now = now.advanced(by: duration) }
}
@MainActor
private final class CLITestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var hasArrived = false
    func pause() async {
        hasArrived = true
        waiter?.resume(); waiter = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func arrived() async {
        if hasArrived { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}
