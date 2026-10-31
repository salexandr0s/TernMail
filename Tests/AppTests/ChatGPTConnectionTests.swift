import Foundation
import Observation
import TernAI
import Testing
@testable import Tern

@MainActor
@Suite struct ChatGPTConnectionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    @Test func initializationDoesNotReadAndConcurrentRestorationSharesOneLoad() async throws {
        let saved = try credentials(token: "saved", expires: now.addingTimeInterval(3600))
        let store = try ConnectionMemoryStore(record: record(saved))
        let gate = ConnectionGate()
        store.loadGate = gate
        let connection = ChatGPTConnection(store: store, auth: stubAuth(), now: { self.now })
        #expect(store.loads == 0)
        #expect(connection.account == nil)
        let change = ConnectionChangeFlag()
        withObservationTracking {
            #expect(!connection.canUsePlan)
        } onChange: {
            MainActor.assumeIsolated { change.didChange = true }
        }
        let first = Task { await connection.recoverPendingConnection() }
        await gate.waitUntilPaused()
        #expect(connection.isRestoring)
        let second = Task { await connection.recoverPendingConnection() }
        first.cancel()
        gate.open()
        await first.value
        await second.value
        #expect(store.loads == 1)
        #expect(!connection.isRestoring)
        #expect(connection.canUsePlan)
        #expect(connection.account?.subject == "subject")
        #expect(change.didChange)
    }

    @Test func cancellingAnOlderCallerDoesNotCancelTheNewConnection() async throws {
        let store = try ConnectionMemoryStore(record: ChatGPTStoredConnection())
        let gate = ConnectionGate()
        store.loadGate = gate
        var browsers = 0
        let connection = ChatGPTConnection(store: store, auth: stubAuth(),
            makeListener: { ConnectionFakeListener() },
            openBrowser: { _ in browsers += 1; return true }, now: { self.now })
        let first = Task { await connection.connect() }
        await gate.waitUntilPaused()
        connection.cancelSignIn()
        let second = Task { await connection.connect() }
        try await waitUntil { connection.isConnecting }
        first.cancel()
        for _ in 0..<10 { await Task.yield() }
        #expect(connection.isConnecting)
        gate.open()
        await first.value
        await second.value
        #expect(browsers == 1)
    }

    @Test func deniedReadRequiresRetryWithoutOverwritingSavedConnection() async throws {
        let saved = try credentials(token: "saved", expires: now.addingTimeInterval(3600))
        let store = try ConnectionMemoryStore(record: record(saved))
        store.failLoads = true
        var browsers = 0
        let connection = ChatGPTConnection(store: store, auth: stubAuth(),
            openBrowser: { _ in browsers += 1; return true }, now: { self.now })
        await connection.recoverPendingConnection()
        await connection.recoverPendingConnection()
        await connection.connect()
        #expect(store.loads == 1)
        #expect(store.saves == 0)
        #expect(browsers == 0)
        #expect(connection.needsStorageRetry)
        #expect(try store.record().credentials?.accessToken == "saved")
        store.failLoads = false
        await connection.retryStoredConnection()
        #expect(store.loads == 2)
        #expect(store.saves == 0)
        #expect(!connection.needsStorageRetry)
        #expect(connection.errorMessage == nil)
        #expect(connection.canUsePlan)
    }

    @Test func disconnectDuringRestorationDoesNotPublishOrLoseTheStoredRegistration() async throws {
        let saved = try credentials(token: "saved", expires: now.addingTimeInterval(3600))
        let store = try ConnectionMemoryStore(record: record(saved))
        let gate = ConnectionGate()
        store.loadGate = gate
        var revoked: String?
        let connection = ChatGPTConnection(store: store,
            auth: stubAuth(revoke: { _, token in revoked = token }), now: { self.now })
        let request = Task { try await connection.accessToken() }
        await gate.waitUntilPaused()
        let disconnect = Task { await connection.disconnect() }
        try await waitUntil { connection.isDisconnecting }
        #expect(store.isDisconnected)
        gate.open()
        await disconnect.value
        await #expect(throws: ChatGPTConnectionError.self) { try await request.value }
        #expect(connection.account == nil)
        #expect(!connection.canUsePlan)
        #expect(revoked == "refresh-saved")
        #expect(try store.record().credentials == nil)
        #expect(try store.record().registration == saved.registration)
    }

    @Test func disconnectWithUnreadStorageOnlySetsTheTombstone() async throws {
        let saved = try credentials(token: "saved", expires: now.addingTimeInterval(3600))
        let store = try ConnectionMemoryStore(record: record(saved))
        store.failLoads = true
        let connection = ChatGPTConnection(store: store, auth: stubAuth(), now: { self.now })
        await connection.disconnect()
        #expect(store.isDisconnected)
        #expect(store.saves == 0)
        #expect(try store.record().registration == saved.registration)
        #expect(try store.record().credentials?.accessToken == "saved")
        #expect(connection.account == nil)
        #expect(connection.errorMessage?.contains("Keychain") == true)
    }

    @Test func concurrentConnectCallsDoNotDuplicateAuthorizationWhileSaving() async throws {
        let store = try ConnectionMemoryStore(record: ChatGPTStoredConnection())
        let gate = ConnectionGate()
        store.beforeSave = { record in if record.registration == nil { await gate.pause() } }
        var browsers = 0
        let connection = ChatGPTConnection(store: store, auth: stubAuth(),
            makeListener: { ConnectionFakeListener() },
            openBrowser: { _ in browsers += 1; return true }, now: { self.now })
        let first = Task { await connection.connect() }
        await gate.waitUntilPaused()
        await connection.connect()
        gate.open()
        await first.value
        #expect(browsers == 1)
        #expect(!connection.isConnecting)
    }

    @Test func disconnectDuringCredentialInstallationClearsTheLateWrite() async throws {
        let saved = try credentials(token: "new", expires: now.addingTimeInterval(3600))
        let pending = try pending(saved)
        var initial = ChatGPTStoredConnection()
        initial.hostID = saved.registration.hostID
        let store = try ConnectionMemoryStore(record: initial)
        let gate = ConnectionGate()
        store.beforeSave = { value in
            if value.credentials?.accessToken == "new", value.pending == nil { await gate.pause() }
        }
        var revoked: [String] = []
        let connection = ChatGPTConnection(store: store,
            auth: stubAuth(exchange: { _, _ in pending }, verify: { _ in saved },
                revoke: { _, token in revoked.append(token) }),
            makeListener: { ConnectionFakeListener() }, openBrowser: { _ in true }, now: { self.now })
        let login = Task { await connection.connect() }
        await gate.waitUntilPaused()
        let disconnect = Task { await connection.disconnect() }
        try await waitUntil { connection.isDisconnecting }
        #expect(store.isDisconnected)
        gate.open()
        await login.value
        await disconnect.value
        #expect(connection.account == nil)
        #expect(!connection.canUsePlan)
        #expect(try store.record().credentials == nil)
        #expect(try store.record().pending == nil)
        #expect(revoked == ["refresh-new"])
    }

    @Test func concurrentRequestsShareRotationAndCancelledCallerDoesNotLoseIt() async throws {
        let old = try credentials(token: "old", expires: now.addingTimeInterval(10))
        let replacement = try credentials(token: "new", expires: now.addingTimeInterval(3600))
        let pending = try pending(replacement)
        let store = try ConnectionMemoryStore(record: record(old))
        let gate = ConnectionGate()
        var refreshes = 0
        let auth = stubAuth(refresh: { _ in refreshes += 1; return pending }, verify: { _ in
            let saved = try store.record()
            #expect(saved.pending?.accessToken == "new")
            await gate.pause()
            return replacement
        })
        let connection = ChatGPTConnection(store: store, auth: auth, now: { self.now })
        let first = Task { try await connection.accessToken() }
        await gate.waitUntilPaused()
        #expect(connection.canUsePlan)
        let second = Task { try await connection.accessToken() }
        first.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == "new")
        #expect(refreshes == 1)
        #expect(try store.record().credentials?.accessToken == "new")
        #expect(try store.record().pending == nil)
        #expect(connection.connectionRevision == 0)
    }

    @Test func disconnectWaitsForRotationAndRevokesReplacementWithoutRestoringAccount() async throws {
        let old = try credentials(token: "old", expires: now.addingTimeInterval(10))
        let replacement = try credentials(token: "new", expires: now.addingTimeInterval(3600))
        let pending = try pending(replacement)
        let store = try ConnectionMemoryStore(record: record(old))
        let gate = ConnectionGate()
        var revoked: String?
        let auth = stubAuth(refresh: { _ in pending }, verify: { _ in
            await gate.pause(); return replacement
        }, revoke: { _, token in
            let saved = try store.record()
            #expect(saved.credentials == nil)
            revoked = token
        })
        let connection = ChatGPTConnection(store: store, auth: auth, now: { self.now })
        let request = Task { try await connection.accessToken() }
        await gate.waitUntilPaused()
        let disconnect = Task { await connection.disconnect() }
        try await waitUntil { connection.isDisconnecting }
        #expect(connection.account == nil)
        gate.open()
        await disconnect.value
        await #expect(throws: (any Error).self) { try await request.value }
        #expect(revoked == "refresh-new")
        #expect(connection.account == nil)
        #expect(!connection.canUsePlan)
        #expect(try store.record().pending == nil)
        #expect(try store.record().registration?.clientID == "oaiapp_tern_test")
    }

    @Test func registrationAndPendingCredentialsSurviveInterruptedVerification() async throws {
        let connected = try credentials(token: "new", expires: now.addingTimeInterval(3600))
        let pending = try pending(connected)
        var initial = ChatGPTStoredConnection()
        initial.hostID = connected.registration.hostID
        let store = try ConnectionMemoryStore(record: initial)
        let listener = ConnectionFakeListener()
        var exchanges = 0
        let auth = stubAuth(exchange: { code, _ in
            let saved = try store.record()
            #expect(saved.registration?.clientID == code.registration.clientID)
            exchanges += 1
            return pending
        }, verify: { _ in throw ChatGPTAuthError.unavailable })
        let connection = ChatGPTConnection(store: store, auth: auth, makeListener: { listener },
            openBrowser: { _ in true }, now: { self.now })
        await connection.connect()
        #expect(connection.account == nil)
        #expect(try store.record().pending?.accessToken == "new")
        #expect(listener.cancelled)
        let recovered = ChatGPTConnection(store: store, auth: stubAuth(verify: { _ in connected }), now: { self.now })
        await recovered.recoverPendingConnection()
        #expect(recovered.account?.subject == "subject")
        #expect(try await recovered.accessToken() == "new")
        #expect(exchanges == 1)
        #expect(try store.record().pending == nil)
    }

    @Test func cancellingLoginPreventsLateVerificationFromReconnecting() async throws {
        let connected = try credentials(token: "new", expires: now.addingTimeInterval(3600))
        let pending = try pending(connected)
        var initial = ChatGPTStoredConnection()
        initial.hostID = connected.registration.hostID
        let store = try ConnectionMemoryStore(record: initial)
        let gate = ConnectionGate()
        let auth = stubAuth(exchange: { _, _ in pending }, verify: { _ in await gate.pause(); return connected })
        let listener = ConnectionFakeListener()
        let connection = ChatGPTConnection(store: store, auth: auth, makeListener: { listener },
            openBrowser: { _ in true }, now: { self.now })
        let login = Task { await connection.connect() }
        await gate.waitUntilPaused()
        connection.cancelSignIn()
        gate.open()
        await login.value
        #expect(connection.account == nil)
        #expect(!connection.isConnecting)
        #expect(try store.record().credentials == nil)
        #expect(try store.record().pending == nil)
    }

    @Test func reconnectCheckpointRecoversAfterDisconnectedConnection() async throws {
        let old = try credentials(token: "old", expires: now.addingTimeInterval(3600))
        let replacement = try credentials(token: "new", expires: now.addingTimeInterval(3600))
        let pending = try pending(replacement)
        let store = try ConnectionMemoryStore(record: record(old))
        let connection = ChatGPTConnection(store: store,
            auth: stubAuth(exchange: { _, _ in pending }, verify: { _ in throw ChatGPTAuthError.unavailable }),
            makeListener: { ConnectionFakeListener() }, openBrowser: { _ in true }, now: { self.now })
        await connection.disconnect()
        #expect(store.isDisconnected)
        await connection.connect()
        #expect(connection.account == nil)
        #expect(!store.isDisconnected)
        #expect(try store.record().credentials == nil)
        #expect(try store.record().pending?.accessToken == "new")
        let restarted = ChatGPTConnection(store: store, auth: stubAuth(verify: { _ in replacement }), now: { self.now })
        await restarted.recoverPendingConnection()
        #expect(try await restarted.accessToken() == "new")
        #expect(restarted.account?.subject == "subject")
    }

    @Test func disconnectAwaitsCancelledLoginRevocation() async throws {
        let connected = try credentials(token: "new", expires: now.addingTimeInterval(3600))
        let pending = try pending(connected)
        var initial = ChatGPTStoredConnection()
        initial.hostID = connected.registration.hostID
        let store = try ConnectionMemoryStore(record: initial)
        let verification = ConnectionGate()
        let revocation = ConnectionGate()
        let connection = ChatGPTConnection(store: store,
            auth: stubAuth(exchange: { _, _ in pending }, verify: { _ in await verification.pause(); return connected },
                revoke: { _, _ in await revocation.pause(); throw ChatGPTAuthError.unavailable }),
            makeListener: { ConnectionFakeListener() }, openBrowser: { _ in true }, now: { self.now })
        let login = Task { await connection.connect() }
        await verification.waitUntilPaused()
        let disconnect = Task { await connection.disconnect() }
        await revocation.waitUntilPaused()
        #expect(connection.isDisconnecting)
        revocation.open()
        verification.open()
        await disconnect.value
        await login.value
        #expect(connection.account == nil)
        #expect(connection.errorMessage?.contains("Remote revocation") == true)
    }

    @Test func disconnectRevokesTokensReturnedByCancelledExchange() async throws {
        let connected = try credentials(token: "late", expires: now.addingTimeInterval(3600))
        let pending = try pending(connected)
        var initial = ChatGPTStoredConnection()
        initial.hostID = connected.registration.hostID
        let store = try ConnectionMemoryStore(record: initial)
        let exchange = ConnectionGate()
        var revoked: String?
        var verifications = 0
        let connection = ChatGPTConnection(store: store,
            auth: stubAuth(exchange: { _, _ in await exchange.pause(); return pending },
                verify: { _ in verifications += 1; return connected },
                revoke: { _, token in revoked = token; throw ChatGPTAuthError.unavailable }),
            makeListener: { ConnectionFakeListener() }, openBrowser: { _ in true }, now: { self.now })
        let login = Task { await connection.connect() }
        await exchange.waitUntilPaused()
        let disconnect = Task { await connection.disconnect() }
        try await waitUntil { connection.isDisconnecting }
        exchange.open()
        await disconnect.value
        await login.value
        #expect(revoked == "refresh-late")
        #expect(verifications == 0)
        #expect(connection.account == nil)
        #expect(!connection.canUsePlan)
        #expect(try store.record().credentials == nil)
        #expect(try store.record().pending == nil)
        #expect(connection.errorMessage?.contains("Remote revocation") == true)
    }

    @Test func uncertainRefreshCannotReplayOldRotatingToken() async throws {
        let old = try credentials(token: "old", expires: now.addingTimeInterval(10))
        let store = try ConnectionMemoryStore(record: record(old))
        var refreshes = 0
        let auth = stubAuth(refresh: { _ in refreshes += 1; throw ChatGPTAuthError.renewalUncertain })
        let connection = ChatGPTConnection(store: store, auth: auth, now: { self.now })
        await #expect(throws: ChatGPTAuthError.renewalUncertain) { try await connection.accessToken() }
        let restarted = ChatGPTConnection(store: store, auth: auth, now: { self.now })
        await #expect(throws: ChatGPTAuthError.renewalUncertain) { try await restarted.accessToken() }
        #expect(refreshes == 1)
        #expect(!restarted.canUsePlan)
        #expect(try store.record().registration?.clientID == "oaiapp_tern_test")
    }

    @Test func identityOnlyConnectionCannotInvokeInference() async throws {
        let identity = try credentials(token: "identity", expires: now.addingTimeInterval(3600), scopes: ["openid", "email"])
        let store = try ConnectionMemoryStore(record: record(identity))
        let connection = ChatGPTConnection(store: store, auth: stubAuth(), now: { self.now })
        await connection.recoverPendingConnection()
        #expect(connection.account?.subject == "subject")
        #expect(!connection.canUsePlan)
        await #expect(throws: ChatGPTConnectionError.self) { try await connection.accessToken() }
    }

    @Test func enablingPlanUsageRequestsFreshConsent() async throws {
        let identity = try credentials(token: "identity", expires: now.addingTimeInterval(3600), scopes: ["openid", "email"])
        let store = try ConnectionMemoryStore(record: record(identity))
        var browserURL: URL?
        let connection = ChatGPTConnection(store: store, auth: stubAuth(), makeListener: { ConnectionFakeListener() },
            openBrowser: { browserURL = $0; return true }, now: { self.now })
        await connection.connect()
        let components = try #require(browserURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(components.queryItems?.first(where: { $0.name == "prompt" })?.value == "consent")
    }

    @Test func failedCredentialClearCannotReconnectAfterRelaunch() async throws {
        let credentials = try credentials(token: "old", expires: now.addingTimeInterval(3600))
        let store = try ConnectionMemoryStore(record: record(credentials))
        let connection = ChatGPTConnection(store: store, auth: stubAuth(revoke: { _, _ in throw ChatGPTAuthError.unavailable }), now: { self.now })
        store.failSaves = true
        await connection.disconnect()
        #expect(store.isDisconnected)
        #expect(connection.errorMessage?.contains("Keychain") == true)
        // The simulated failed Keychain write retains the old credential, but
        // the independently persisted disconnection still denies access.
        #expect(try store.record().credentials?.accessToken == "old")
        let restarted = ChatGPTConnection(store: store, auth: stubAuth(), now: { self.now })
        #expect(restarted.account == nil)
        #expect(!restarted.canUsePlan)
        await #expect(throws: ChatGPTConnectionError.self) { try await restarted.accessToken() }
        store.failSaves = false
        let cleaned = ChatGPTConnection(store: store, auth: stubAuth(), now: { self.now })
        await cleaned.recoverPendingConnection()
        #expect(try store.record().credentials == nil)
        #expect(try store.record().registration?.clientID == "oaiapp_tern_test")
        #expect(cleaned.account == nil)
        #expect(cleaned.errorMessage == nil)
    }

    @Test func loopbackRejectsWrongHostOriginMethodAndDuplicateState() throws {
        let callback = try #require(URL(string: "http://127.0.0.1:43210/auth/callback"))
        func request(_ line: String = "GET /auth/callback?state=expected&code=code HTTP/1.1",
                     host: String = "127.0.0.1:43210", extra: String = "") -> Data {
            Data("\(line)\r\nHost: \(host)\r\n\(extra)\r\n".utf8)
        }
        #expect(LoopbackAuthListener.validatedRequest(request(), callbackURL: callback, expectedState: "expected") != nil)
        let invalid = [
            request(host: "localhost:43210"),
            request(extra: "Origin: https://unrelated.invalid\r\n"),
            request("POST /auth/callback?state=expected HTTP/1.1"),
            request("GET //unrelated.invalid/auth/callback?state=expected HTTP/1.1"),
            request("GET /auth/callback?state=wrong HTTP/1.1"),
            request("GET /auth/callback?state=expected&state=expected HTTP/1.1"),
            request(extra: "Host: 127.0.0.1:43210\r\n"),
        ]
        for data in invalid {
            #expect(LoopbackAuthListener.validatedRequest(data, callbackURL: callback, expectedState: "expected") == nil)
        }
    }

    @Test func loopbackKeepsWaitingAfterUnrelatedRequest() async throws {
        let listener = LoopbackAuthListener(timeout: .seconds(10))
        let callback = try await listener.start()
        defer { listener.cancel() }
        listener.expect(state: "expected")
        let waiting = Task { try await listener.callback() }
        var wrong = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        wrong?.queryItems = [URLQueryItem(name: "state", value: "wrong")]
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, rejected) = try await session.data(from: #require(wrong?.url))
        #expect((rejected as? HTTPURLResponse)?.statusCode == 400)
        var right = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        right?.queryItems = [URLQueryItem(name: "state", value: "expected"), URLQueryItem(name: "code", value: "code")]
        let rightURL = try #require(right?.url)
        let (_, accepted) = try await session.data(from: rightURL)
        #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await waiting.value == rightURL)
    }

    private func credentials(token: String, expires: Date, scopes: [String] = ["openid", "resource.invoke", "chatgpt.tokens.use.direct"]) throws -> ChatGPTCredentials {
        let data = try JSONSerialization.data(withJSONObject: [
            "registration": ["clientID": "oaiapp_tern_test", "hostID": "urn:uuid:8687c530-38cb-4d7d-ac63-0a235a03ba16", "subject": "subject", "email": "test@example.invalid"],
            "account": ["subject": "subject", "email": "test@example.invalid", "name": "Test"],
            "accessToken": token, "refreshToken": "refresh-" + token, "idToken": "synthetic.id.token",
            "scopes": scopes, "receivedAt": now.timeIntervalSinceReferenceDate,
            "expiresAt": expires.timeIntervalSinceReferenceDate,
        ])
        return try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
    }

    private func pending(_ credentials: ChatGPTCredentials) throws -> ChatGPTPendingTokens {
        try JSONDecoder().decode(ChatGPTPendingTokens.self, from: JSONEncoder().encode(credentials))
    }

    private func record(_ credentials: ChatGPTCredentials) -> ChatGPTStoredConnection {
        var record = ChatGPTStoredConnection()
        record.hostID = credentials.registration.hostID
        record.registration = credentials.registration
        record.credentials = credentials
        return record
    }

    private func stubAuth(
        exchange: @escaping (ChatGPTAuthorizationCode, ChatGPTAuthorizationAttempt) async throws -> ChatGPTPendingTokens = { _, _ in throw ChatGPTAuthError.unavailable },
        refresh: @escaping (ChatGPTCredentials) async throws -> ChatGPTPendingTokens = { _ in throw ChatGPTAuthError.unavailable },
        verify: @escaping (ChatGPTPendingTokens) async throws -> ChatGPTCredentials = { _ in throw ChatGPTAuthError.unavailable },
        revoke: @escaping (ChatGPTRegistration, String) async throws -> Void = { _, _ in }
    ) -> ChatGPTConnectionAuth {
        ChatGPTConnectionAuth(exchange: exchange, refresh: refresh, verify: verify, revoke: revoke)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        throw ChatGPTConnectionError.invalidated
    }
}

@MainActor
private final class ConnectionChangeFlag {
    var didChange = false
}

@MainActor
private final class ConnectionMemoryStore: AIConnectionStore {
    private var data: Data
    private(set) var isDisconnected = false
    var failSaves = false
    var failLoads = false
    private(set) var loads = 0
    private(set) var saves = 0
    var loadGate: ConnectionGate?
    var beforeSave: ((ChatGPTStoredConnection) async -> Void)?
    init(record: ChatGPTStoredConnection) throws { data = try JSONEncoder().encode(record) }
    func load() async throws -> Data? {
        loads += 1
        if failLoads { throw AIKeychainFailure() }
        if let loadGate { await loadGate.pause() }
        return data
    }
    func save(_ data: Data) async throws {
        saves += 1
        if failSaves { throw AIKeychainFailure() }
        if let beforeSave { await beforeSave(try JSONDecoder().decode(ChatGPTStoredConnection.self, from: data)) }
        self.data = data
    }
    func setDisconnected(_ disconnected: Bool) { isDisconnected = disconnected }
    func record() throws -> ChatGPTStoredConnection { try JSONDecoder().decode(ChatGPTStoredConnection.self, from: data) }
}

@MainActor
private final class ConnectionGate {
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
private final class ConnectionFakeListener: ChatGPTCallbackListener {
    var state = ""
    var cancelled = false
    func start() async throws -> URL {
        try #require(URL(string: "http://127.0.0.1:43210/auth/callback"))
    }
    func expect(state: String) { self.state = state }
    func callback() async throws -> URL {
        var url = URLComponents(string: "http://127.0.0.1:43210/auth/callback")
        url?.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "test-code"),
                          URLQueryItem(name: "client_id", value: "oaiapp_tern_test")]
        return try #require(url?.url)
    }
    func cancel() { cancelled = true }
}
