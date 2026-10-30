import Foundation
import Network

@MainActor
protocol ChatGPTCallbackListener: AnyObject {
    func start() async throws -> URL
    func expect(state: String)
    func callback() async throws -> URL
    func cancel()
}

enum ChatGPTConnectionError: Error, LocalizedError {
    case notConnected, planPermission, listenerUnavailable, signInTimedOut, browserUnavailable
    case malformedStorage, invalidated

    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect your ChatGPT account to use the assistant."
        case .planPermission: "Allow Tern to use your ChatGPT plan, then reconnect."
        case .listenerUnavailable: "Tern could not open the local sign-in callback. Please try again."
        case .signInTimedOut: "ChatGPT sign-in timed out. Please start again."
        case .browserUnavailable: "Tern could not open your browser. Check your default browser and try again."
        case .malformedStorage: "The saved ChatGPT connection could not be read. Please check Keychain access."
        case .invalidated: "The ChatGPT connection changed. Please try again."
        }
    }
}

/// A temporary HTTP endpoint used only for the browser's OAuth redirect.
@MainActor
final class LoopbackAuthListener: ChatGPTCallbackListener {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<URL, any Error>?
    private var callbackContinuation: CheckedContinuation<URL, any Error>?
    private var callbackURL: URL?
    private var expectedState: String?
    private var result: Result<URL, any Error>?
    private var deadline: Task<Void, Never>?
    private let timeout: Duration

    init(timeout: Duration = .seconds(600)) { self.timeout = timeout }

    func start() async throws -> URL {
        guard listener == nil, result == nil else { throw ChatGPTConnectionError.listenerUnavailable }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw ChatGPTConnectionError.listenerUnavailable }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                listener.start(queue: .main)
                deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finish(.failure(ChatGPTConnectionError.signInTimedOut))
                }
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func expect(state: String) { expectedState = state }

    func callback() async throws -> URL {
        guard callbackContinuation == nil, expectedState != nil else { throw ChatGPTConnectionError.listenerUnavailable }
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callbackContinuation = continuation
                if Task.isCancelled { cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else {
                finish(.failure(ChatGPTConnectionError.listenerUnavailable)); return
            }
            callbackURL = url
            startContinuation?.resume(returning: url)
            startContinuation = nil
        case .failed:
            finish(.failure(ChatGPTConnectionError.listenerUnavailable))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { connection.cancel(); return }
                var data = buffer
                if let bytes { data.append(bytes) }
                guard data.count <= 16_384, error == nil else {
                    self.reply(connection, id: id, accepted: false); return
                }
                if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    guard let callbackURL = self.callbackURL, let state = self.expectedState,
                          let candidate = Self.validatedRequest(data, callbackURL: callbackURL, expectedState: state) else {
                        self.reply(connection, id: id, accepted: false); return
                    }
                    self.reply(connection, id: id, accepted: true)
                    self.finish(.success(candidate), preserving: id)
                } else if complete {
                    self.reply(connection, id: id, accepted: false)
                } else {
                    self.receive(connection, id: id, buffer: data)
                }
            }
        }
    }

    /// Invalid state leaves the pending sign-in available for the legitimate browser callback.
    static func validatedRequest(_ data: Data, callbackURL: URL, expectedState: String) -> URL? {
        guard data.count <= 16_384, let request = String(data: data, encoding: .utf8),
              let boundary = request.range(of: "\r\n\r\n") else { return nil }
        let lines = request[..<boundary.lowerBound].components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
              let port = callbackURL.port else { return nil }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { return nil }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key, default: []].append(value)
        }
        let origin = "http://127.0.0.1:\(port)"
        guard headers["host"] == ["127.0.0.1:\(port)"], headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == ["0"],
              headers["origin"] == nil || headers["origin"] == [origin],
              let candidate = URL(string: origin + parts[1]),
              let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              components.path == callbackURL.path, components.fragment == nil,
              components.host == "127.0.0.1", components.port == port else { return nil }
        let states = (components.queryItems ?? []).filter { $0.name == "state" }
        guard states.count == 1, let returned = states[0].value,
              equalState(returned, expectedState) else { return nil }
        return candidate
    }

    private static func equalState(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func reply(_ connection: NWConnection, id: UUID, accepted: Bool) {
        let body = accepted
            ? "ChatGPT returned to Tern. You can close this tab while Tern verifies the connection."
            : "This request did not match the pending sign-in. Return to the browser tab that started it."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
            + "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n"
            + "Connection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
    }

    private func finish(_ result: Result<URL, any Error>, preserving id: UUID? = nil) {
        guard self.result == nil else { return }
        self.result = result
        deadline?.cancel(); deadline = nil
        listener?.cancel(); listener = nil
        for (key, connection) in connections where key != id { connection.cancel(); connections.removeValue(forKey: key) }
        if let startContinuation { startContinuation.resume(with: result); self.startContinuation = nil }
        if let callbackContinuation { callbackContinuation.resume(with: result); self.callbackContinuation = nil }
    }
}
