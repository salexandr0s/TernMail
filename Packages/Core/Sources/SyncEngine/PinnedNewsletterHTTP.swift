import Foundation
import MessageContent
import Network
import Security
import Synchronization

/// Sends one RFC 8058 request to an address already checked by the DNS policy.
/// A numeric Network.framework endpoint prevents URLSession from resolving the
/// name a second time. TLS still verifies the sender's original DNS name.
enum PinnedNewsletterHTTP {
    static func post(_ request: URLRequest, address: String, hostname: String) async throws {
        guard let url = request.url, url.scheme == "https", url.host == hostname,
              NewsletterNetworkPolicy.isPublicNumericAddress(address),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let body = request.httpBody else { throw NewsletterTransportError.unsafeURL }
        let bytes = try requestBytes(components: components, hostname: hostname, body: body)

        let tls = NWProtocolTLS.Options()
        hostname.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = PinnedNewsletterConnection(address: address, parameters: parameters)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak connection] in
            connection?.fail(URLError(.timedOut))
        }
        try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await connection.ready()
            try await connection.send(bytes)
            var received = Data()
            var consumedHeaderBytes = 0
            while true {
                let (chunk, complete) = try await connection.receive()
                if let chunk { received.append(chunk) }
                if let response = try finalResponseHeaders(in: &received, consumedHeaderBytes: &consumedHeaderBytes) {
                    if (200..<300).contains(response.status) { return }
                    throw NewsletterTransportError.refused(response.status)
                }
                if complete { break }
            }
            throw NewsletterTransportError.invalidResponse
        } onCancel: { connection.fail(CancellationError()) }
    }

    static func requestBytes(components: URLComponents, hostname: String, body: Data) throws -> Data {
        guard NewsletterURLPolicy.isPublicHostname(hostname) else { throw NewsletterTransportError.unsafeURL }
        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery { target += "?" + query }
        guard !target.contains("\r"), !target.contains("\n"), target.utf8.count <= 8_192 else {
            throw NewsletterTransportError.unsafeURL
        }
        let headers = "POST \(target) HTTP/1.1\r\nHost: \(hostname)\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var bytes = Data(headers.utf8)
        bytes.append(body)
        return bytes
    }

    static func responseHeaders(in data: Data) throws -> (status: Int, endIndex: Data.Index)? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw NewsletterTransportError.invalidResponse }
            return nil
        }
        guard boundary.upperBound <= 16_384 else { throw NewsletterTransportError.invalidResponse }
        let line = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n").first ?? ""
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(fields[0])),
              fields[1].count == 3, let status = Int(fields[1]) else {
            throw NewsletterTransportError.invalidResponse
        }
        return (status, boundary.upperBound)
    }

    /// Interim responses and the final response share one header-byte budget,
    /// including when a peer sends each interim response in a separate packet.
    static func finalResponseHeaders(in data: inout Data, consumedHeaderBytes: inout Int) throws -> (status: Int, endIndex: Data.Index)? {
        while let response = try responseHeaders(in: data) {
            let count = data.distance(from: data.startIndex, to: response.endIndex)
            guard count <= 16_384 - consumedHeaderBytes else { throw NewsletterTransportError.invalidResponse }
            guard (100..<200).contains(response.status), response.status != 101 else { return response }
            consumedHeaderBytes += count
            data.removeSubrange(..<response.endIndex)
        }
        guard data.count <= 16_384 - consumedHeaderBytes else { throw NewsletterTransportError.invalidResponse }
        return nil
    }
}

/// NWConnection callbacks can arrive on different queues. The mutex owns all
/// continuations; a failure, cancellation, or callback resumes each at most once.
final class PinnedNewsletterConnection: @unchecked Sendable {
    private typealias Chunk = (Data?, Bool)
    private struct State {
        var failure: (any Error)?
        var ready: CheckedContinuation<Void, any Error>?
        var send: CheckedContinuation<Void, any Error>?
        var receive: CheckedContinuation<Chunk, any Error>?
    }
    private let state = Mutex(State())
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.tern.newsletter.pinned")

    init(address: String, parameters: NWParameters) {
        connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(address), port: .https), using: parameters)
    }

    func ready() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let failure = state.withLock { state -> (any Error)? in
                if let failure = state.failure { return failure }
                state.ready = continuation
                return nil
            }
            if let failure { continuation.resume(throwing: failure); return }
            connection.stateUpdateHandler = { [weak self] status in
                guard let self else { return }
                switch status {
                case .ready:
                    let waiting = self.state.withLock { state -> CheckedContinuation<Void, any Error>? in
                        defer { state.ready = nil }
                        return state.ready
                    }
                    waiting?.resume()
                case .failed(let error): self.fail(error)
                case .cancelled: self.fail(CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let failure = state.withLock { state -> (any Error)? in
                if let failure = state.failure { return failure }
                state.send = continuation
                return nil
            }
            if let failure { continuation.resume(throwing: failure); return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                let waiting = self.state.withLock { state -> CheckedContinuation<Void, any Error>? in
                    defer { state.send = nil }
                    return state.send
                }
                if let error { waiting?.resume(throwing: error) }
                else { waiting?.resume() }
            })
        }
    }

    func receive() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            let failure = state.withLock { state -> (any Error)? in
                if let failure = state.failure { return failure }
                state.receive = continuation
                return nil
            }
            if let failure { continuation.resume(throwing: failure); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
                guard let self else { return }
                let waiting = self.state.withLock { state -> CheckedContinuation<Chunk, any Error>? in
                    defer { state.receive = nil }
                    return state.receive
                }
                if let error { waiting?.resume(throwing: error) }
                else { waiting?.resume(returning: (data, complete)) }
            }
        }
    }

    func cancel() { connection.cancel() }

    func fail(_ error: any Error) {
        let pending = state.withLock { state -> (CheckedContinuation<Void, any Error>?,
                                               CheckedContinuation<Void, any Error>?,
                                               CheckedContinuation<Chunk, any Error>?) in
            guard state.failure == nil else { return (nil, nil, nil) }
            state.failure = error
            defer { state.ready = nil; state.send = nil; state.receive = nil }
            return (state.ready, state.send, state.receive)
        }
        pending.0?.resume(throwing: error)
        pending.1?.resume(throwing: error)
        pending.2?.resume(throwing: error)
        connection.cancel()
    }
}
