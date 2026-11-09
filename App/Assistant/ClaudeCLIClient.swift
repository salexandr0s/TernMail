import Foundation
import Security
import Synchronization
import TernAI

struct ClaudeCLIIdentity: Codable, Equatable, Sendable {
    let accountFingerprint: String
    let authMethod: String?
    let subscriptionType: String?

    init(status: ClaudeCLIStatus) throws {
        guard status.available, status.loggedIn,
              let fingerprint = status.accountFingerprint,
              fingerprint.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else {
            throw ClaudeCLIConnectionError.identityUnavailable
        }
        accountFingerprint = fingerprint
        authMethod = status.authMethod
        subscriptionType = status.subscriptionType
    }
}

enum ClaudeCLIConnectionError: Error, LocalizedError, Sendable {
    case helperUnavailable, notInstalled, signInRequired, identityUnavailable, accountChanged
    case invalidResponse, signInFailed, requestFailed, invalidCode, timedOut

    var errorDescription: String? {
        switch self {
        case .helperUnavailable: "Tern could not connect to its Claude helper. Reopen Tern and try again."
        case .notInstalled: "Install the official native Claude Code CLI, then check again."
        case .signInRequired: "Sign in through Claude Code to connect Claude to Tern."
        case .identityUnavailable: "Claude Code did not provide an account identity Tern could verify. Sign in again."
        case .accountChanged: "The Claude Code account or billing method changed. Connect again to confirm this connection."
        case .invalidResponse: "The Claude helper returned a response Tern could not read."
        case .signInFailed: "Claude Code sign-in did not finish. Try signing in again."
        case .requestFailed: "Claude Code could not complete this request. Check its connection and try again."
        case .invalidCode: "Paste the complete sign-in code shown by Claude."
        case .timedOut: "Claude Code took too long to respond. Try again."
        }
    }

    static func helper(_ code: String?) -> any Error {
        switch code {
        case "cancelled": CancellationError()
        case "not_installed", "cli_not_found": Self.notInstalled
        case "not_authenticated", "sign_in_required": Self.signInRequired
        case "account_changed", "auth_changed", "accountChanged": Self.accountChanged
        case "login_failed", "auth_failed": Self.signInFailed
        case "timed_out", "timeout", "timedOut": Self.timedOut
        case "unavailable": Self.helperUnavailable
        case "busy": AIProviderError.busy
        case "invalidRequest": AIProviderError.invalidRequest
        case "outputLimit": AIProviderError.responseLimit
        case "invalidOutput": Self.invalidResponse
        default: Self.requestFailed
        }
    }
}

/// Operations are injectable; test hosts never construct a live XPC connection.
struct ClaudeCLIClient: Sendable {
    var status: @Sendable () async throws -> ClaudeCLIStatus
    var login: @Sendable (String, @escaping @Sendable (Data) -> Void) async throws -> Void
    var submitLoginCode: @Sendable (String, String) async throws -> Void
    var run: @Sendable (ClaudeCLIRequest, ClaudeCLIIdentity) -> AsyncThrowingStream<Data, any Error>
    var cancel: @Sendable (String) -> Void
    var cancelAll: @Sendable () -> Void

    static var live: Self {
        let bridge = ClaudeXPCClient()
        return Self(status: { try await bridge.status() },
            login: { try await bridge.login($0, onEvent: $1) },
            submitLoginCode: { try await bridge.submitLoginCode($0, requestID: $1) },
            run: { bridge.run($0, identity: $1) }, cancel: { bridge.cancel($0) }, cancelAll: { bridge.cancelAll() })
    }

    static var unavailable: Self {
        Self(status: { throw ClaudeCLIConnectionError.helperUnavailable },
            login: { _, _ in throw ClaudeCLIConnectionError.helperUnavailable },
            submitLoginCode: { _, _ in throw ClaudeCLIConnectionError.helperUnavailable },
            run: { _, _ in AsyncThrowingStream { $0.finish(throwing: ClaudeCLIConnectionError.helperUnavailable) } },
            cancel: { _ in }, cancelAll: {})
    }
}

/// NSXPCConnection supports concurrent messaging. The mutex protects its lifetime
/// and every pending callback; callbacks resume outside the lock.
private final class ClaudeXPCClient: @unchecked Sendable {
    private final class Connection: @unchecked Sendable {
        let id = UUID()
        let value: NSXPCConnection
        init(_ value: NSXPCConnection) { self.value = value }
    }
    private struct Pending {
        var reply: CheckedContinuation<Data, any Error>?
        var stream: AsyncThrowingStream<Data, any Error>.Continuation?
        var onEvent: (@Sendable (Data) -> Void)?
        var timeout: Task<Void, Never>?
        var bytes = 0
        var remoteID: String?
    }
    private struct State {
        var connection: Connection?
        var pending: [String: Pending] = [:]
    }
    private let state = Mutex(State())
    private let sendQueue = DispatchQueue(label: "dev.tern.claude-xpc-send", qos: .userInitiated)

    deinit { state.withLock { $0.connection?.value.invalidate() } }

    func status() async throws -> ClaudeCLIStatus {
        // Cancelling or timing out also stops the helper's check, so it frees its job slot.
        let id = UUID().uuidString
        let data = try await request(id: id, remoteID: id, timeout: .seconds(30)) { proxy, reply in proxy.status(id, withReply: reply) }
        guard data.count <= 65_536,
              let result = try? JSONDecoder().decode(ClaudeCLIStatus.self, from: data) else {
            throw ClaudeCLIConnectionError.invalidResponse
        }
        if let errorCode = result.errorCode { throw ClaudeCLIConnectionError.helper(errorCode) }
        return result
    }

    func login(_ requestID: String, onEvent: @escaping @Sendable (Data) -> Void) async throws {
        let data = try await request(id: requestID, remoteID: requestID, timeout: .seconds(600), onEvent: onEvent) { proxy, reply in
            proxy.login(requestID, withReply: reply)
        }
        try Self.checkReply(data)
    }

    func submitLoginCode(_ code: String, requestID: String) async throws {
        let data = try await request(timeout: .seconds(30)) { proxy, reply in
            proxy.submitLoginCode(code, requestID: requestID, withReply: reply)
        }
        try Self.checkReply(data)
    }

    func run(_ request: ClaudeCLIRequest, identity: ClaudeCLIIdentity) -> AsyncThrowingStream<Data, any Error> {
        let id = UUID().uuidString
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            register(id, pending: Pending(stream: continuation, remoteID: id), timeout: .seconds(180))
            sendQueue.async { [self] in
                do {
                    guard isPending(id) else { return }
                    let requestData = try JSONEncoder().encode(request)
                    guard requestData.count <= 524_288 else { throw AIProviderError.invalidRequest }
                    let envelope = ClaudeCLIHelperRunRequest(request: requestData,
                        expectedAccountFingerprint: identity.accountFingerprint, expectedAuthMethod: identity.authMethod,
                        expectedSubscriptionType: identity.subscriptionType)
                    let data = try JSONEncoder().encode(envelope)
                    guard data.count <= 786_432 else { throw AIProviderError.invalidRequest }
                    let connection = try connection()
                    guard isPending(id) else { return }
                    let proxy = try proxy(connection, requestID: id)
                    proxy.run(data, requestID: id) { [weak self] reply in
                        do { try Self.checkReply(reply); self?.finish(id, result: .success(Data())) }
                        catch { self?.finish(id, result: .failure(error)) }
                    }
                } catch {
                    finish(id, result: .failure(error))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in self?.cancel(id) }
        }
    }

    private func request(id: String = UUID().uuidString, remoteID: String? = nil, timeout: Duration,
        onEvent: (@Sendable (Data) -> Void)? = nil,
        send: @escaping @Sendable (any ClaudeCLIHelperProtocol, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                register(id, pending: Pending(reply: continuation, onEvent: onEvent, remoteID: remoteID), timeout: timeout)
                if Task.isCancelled { cancel(id); return }
                sendQueue.async { [self] in
                    do {
                        guard isPending(id) else { return }
                        let connection = try connection()
                        guard isPending(id) else { return }
                        send(try proxy(connection, requestID: id)) { [weak self] data in
                            guard data.count <= 65_536 else {
                                self?.finish(id, result: .failure(ClaudeCLIConnectionError.invalidResponse)); return
                            }
                            self?.finish(id, result: .success(data))
                        }
                    } catch { finish(id, result: .failure(error)) }
                }
            }
        } onCancel: { [weak self] in self?.cancel(id) }
    }

    private func register(_ id: String, pending: Pending, timeout: Duration) {
        var value = pending
        value.timeout = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.cancel(id, error: ClaudeCLIConnectionError.timedOut)
        }
        state.withLock { $0.pending[id] = value }
    }

    func cancel(_ id: String, error: any Error = CancellationError()) {
        let entry = state.withLock { $0.pending.removeValue(forKey: id) }
        if let remoteID = entry?.remoteID {
            sendQueue.async { [self] in
                let connection = state.withLock { $0.connection }
                if let proxy = connection?.value.remoteObjectProxyWithErrorHandler({ _ in }) as? any ClaudeCLIHelperProtocol {
                    proxy.cancel(remoteID)
                }
            }
        }
        complete(entry, result: .failure(error))
    }

    func cancelAll() {
        let ids = state.withLock { Array($0.pending.keys) }
        for id in ids { cancel(id) }
    }

    private func isPending(_ id: String) -> Bool { state.withLock { $0.pending[id] != nil } }

    private func receive(_ line: Data, requestID: String) {
        guard line.count <= 524_288 else { cancel(requestID, error: AIProviderError.responseLimit); return }
        let entry = state.withLock { state -> Pending? in
            guard var pending = state.pending[requestID] else { return nil }
            pending.bytes += line.count
            state.pending[requestID] = pending
            return pending
        }
        guard let entry else { return }
        guard entry.bytes <= 8_388_608 else { cancel(requestID, error: AIProviderError.responseLimit); return }
        if let event = entry.onEvent { event(line) }
        if let stream = entry.stream {
            switch stream.yield(line) {
            case .enqueued: break
            case .dropped: cancel(requestID, error: AIProviderError.responseLimit)
            case .terminated: cancel(requestID)
            @unknown default: cancel(requestID, error: ClaudeCLIConnectionError.invalidResponse)
            }
        }
    }

    private func finish(_ id: String, result: Result<Data, any Error>) {
        complete(state.withLock { $0.pending.removeValue(forKey: id) }, result: result)
    }

    private func complete(_ pending: Pending?, result: Result<Data, any Error>) {
        pending?.timeout?.cancel()
        pending?.reply?.resume(with: result)
        switch result {
        case .success: pending?.stream?.finish()
        case .failure(let error): pending?.stream?.finish(throwing: error)
        }
    }

    private func connection() throws -> Connection {
        try state.withLock { state in
            if let connection = state.connection { return connection }
            let value = NSXPCConnection(serviceName: "dev.tern.mail.ClaudeHelper")
            let connection = Connection(value)
            value.remoteObjectInterface = NSXPCInterface(with: ClaudeCLIHelperProtocol.self)
            value.exportedInterface = NSXPCInterface(with: ClaudeCLIClientProtocol.self)
            value.exportedObject = ClaudeXPCReceiver { [weak self] line, requestID in self?.receive(line, requestID: requestID) }
            let requirement = try ClaudeHelperIdentity.requirement()
            var parsedRequirement: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &parsedRequirement) == errSecSuccess else {
                throw ClaudeCLIConnectionError.helperUnavailable
            }
            value.setCodeSigningRequirement(requirement)
            value.interruptionHandler = { [weak self, id = connection.id] in self?.invalidate(id) }
            value.invalidationHandler = { [weak self, id = connection.id] in self?.invalidate(id) }
            state.connection = connection
            value.resume()
            return connection
        }
    }

    private func proxy(_ connection: Connection, requestID: String) throws -> any ClaudeCLIHelperProtocol {
        guard let proxy = connection.value.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.finish(requestID, result: .failure(ClaudeCLIConnectionError.helperUnavailable))
        }) as? any ClaudeCLIHelperProtocol else { throw ClaudeCLIConnectionError.helperUnavailable }
        return proxy
    }

    private func invalidate(_ id: UUID) {
        let pending = state.withLock { state -> [Pending] in
            guard state.connection?.id == id else { return [] }
            state.connection = nil
            let pending = Array(state.pending.values)
            state.pending.removeAll()
            return pending
        }
        pending.forEach { complete($0, result: .failure(ClaudeCLIConnectionError.helperUnavailable)) }
    }

    private static func checkReply(_ data: Data) throws {
        guard data.count <= 65_536, let reply = try? JSONDecoder().decode(ClaudeCLIHelperReply.self, from: data) else {
            throw ClaudeCLIConnectionError.invalidResponse
        }
        guard reply.success else { throw ClaudeCLIConnectionError.helper(reply.errorCode) }
    }
}

/// Its sole stored property is immutable and Sendable; XPC invokes it serially.
private final class ClaudeXPCReceiver: NSObject, ClaudeCLIClientProtocol, @unchecked Sendable {
    let receiveLine: @Sendable (Data, String) -> Void
    init(_ receive: @escaping @Sendable (Data, String) -> Void) { receiveLine = receive }
    func receive(_ line: Data, requestID: String) { receiveLine(line, requestID) }
}

private enum ClaudeHelperIdentity {
    static func requirement() throws -> String {
        let app = try signingInformation(Bundle.main.bundleURL)
        let helper = try signingInformation(Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/ClaudeHelper.xpc"))
        // The helper accepts calls only from the app its Info.plist names. Use the copy
        // of that plist that strict signature validation just checked.
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty,
              (helper[kSecCodeInfoPList] as? [String: Any])?["TernHostBundleIdentifier"] as? String == bundleIdentifier,
              helper[kSecCodeInfoIdentifier] as? String == "dev.tern.mail.ClaudeHelper" else {
            throw ClaudeCLIConnectionError.helperUnavailable
        }
        if let team = app[kSecCodeInfoTeamIdentifier] as? String {
            guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
                  helper[kSecCodeInfoTeamIdentifier] as? String == team else { throw ClaudeCLIConnectionError.helperUnavailable }
            return "anchor apple generic and identifier \"dev.tern.mail.ClaudeHelper\" and certificate leaf[subject.OU] = \"\(team)\""
        }
        #if DEBUG
        guard helper[kSecCodeInfoTeamIdentifier] == nil, let hash = helper[kSecCodeInfoUnique] as? Data,
              hash.count == 20 || hash.count == 32 else { throw ClaudeCLIConnectionError.helperUnavailable }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "identifier \"dev.tern.mail.ClaudeHelper\" and cdhash H\"\(hex)\""
        #else
        throw ClaudeCLIConnectionError.helperUnavailable
        #endif
    }

    private static func signingInformation(_ url: URL) throws -> [CFString: Any] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw ClaudeCLIConnectionError.helperUnavailable
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let value = information as? [CFString: Any] else { throw ClaudeCLIConnectionError.helperUnavailable }
        return value
    }
}
