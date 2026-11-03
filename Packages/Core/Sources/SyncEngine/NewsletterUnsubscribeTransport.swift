import Darwin
import Foundation
import MessageContent
import Synchronization

public protocol NewsletterUnsubscribeTransport: Sendable {
    func unsubscribe(at url: URL) async throws
}

public enum NewsletterTransportError: Error, LocalizedError, Sendable, Equatable {
    case unsafeURL
    case invalidResponse
    case refused(Int)

    public var errorDescription: String? {
        switch self {
        case .unsafeURL: "This unsubscribe address is not supported."
        case .invalidResponse: "The sender returned an invalid response."
        case .refused: "The sender did not accept the unsubscribe request. Try its website instead."
        }
    }
}

/// RFC 8058 requests have no Gmail authorization, web cookies, or prior web
/// session state. Responses are accepted at headers; their bodies are discarded.
public struct NewsletterHTTPSession: NewsletterUnsubscribeTransport {
    public static let shared = NewsletterHTTPSession()
    private let client: NewsletterHTTPClient
    private let validateHost: @Sendable (String) async throws -> Void
    private let pinsResolvedAddress: Bool

    public init() {
        client = NewsletterHTTPClient(configuration: .ephemeral)
        validateHost = Self.validatePublicHost
        pinsResolvedAddress = true
    }

    /// The override is internal so tests can use a URLProtocol without DNS or
    /// a live subscription. Production always checks every DNS answer.
    init(configuration: URLSessionConfiguration, validateHost: @escaping @Sendable (String) async throws -> Void) {
        client = NewsletterHTTPClient(configuration: configuration)
        self.validateHost = validateHost
        pinsResolvedAddress = false
    }

    public func unsubscribe(at url: URL) async throws {
        try Task.checkCancellation()
        guard let safe = NewsletterURLPolicy.webURL(url.absoluteString, requiresHTTPS: true),
              let host = safe.host else { throw NewsletterTransportError.unsafeURL }
        let address: String?
        if pinsResolvedAddress {
            // The connection below uses this numeric endpoint directly. A
            // second DNS lookup cannot silently replace the checked address.
            address = try await NewsletterDNSCheck.resolve {
                NewsletterNetworkPolicy.publicAddresses(host)
            }.first
            guard address != nil else { throw NewsletterTransportError.unsafeURL }
        } else {
            // Test transports inject URLProtocol and do not resolve DNS.
            try await validateHost(host)
            address = nil
        }
        try Task.checkCancellation()
        var request = URLRequest(url: safe, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        if let address { try await PinnedNewsletterHTTP.post(request, address: address, hostname: host) }
        else { try await client.post(request) }
    }

    private static func validatePublicHost(_ host: String) async throws {
        // DNS lookup is blocking, so keep it off the caller's actor. URLSession
        // performs its own resolution, as it does for sender-logo requests.
        try await NewsletterDNSCheck.validate { NewsletterNetworkPolicy.isPublicHost(host) }
    }
}

/// A stuck resolver cannot keep a canceled window or batch waiting. The OS
/// lookup may finish later, but it cannot start an HTTP request or resume twice.
final class NewsletterDNSCheck: Sendable {
    private struct State {
        var continuation: CheckedContinuation<[String], any Error>?
        var result: Result<[String], any Error>?
    }
    private let state = Mutex(State())

    static func validate(timeout: TimeInterval = 8, resolve: @escaping @Sendable () -> Bool) async throws {
        _ = try await self.resolve(timeout: timeout) { resolve() ? ["valid"] : nil }
    }

    static func resolve(timeout: TimeInterval = 8,
                        lookup: @escaping @Sendable () -> [String]?) async throws -> [String] {
        let check = NewsletterDNSCheck()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let result = check.state.withLock { state -> Result<[String], any Error>? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let result { continuation.resume(with: result); return }
                DispatchQueue.global(qos: .utility).async {
                    check.finish(lookup().map(Result.success) ?? .failure(NewsletterTransportError.unsafeURL))
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    check.finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: { check.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<[String], any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<[String], any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

private final class NewsletterHTTPClient: Sendable {
    let session: URLSession
    private let policy = NewsletterHTTPPolicy()

    init(configuration: URLSessionConfiguration) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func post(_ request: URLRequest) async throws {
        let task = session.dataTask(with: request)
        let pending = NewsletterHTTPPending()
        policy.register(pending, for: task)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.wait(continuation)
                task.resume()
            }
        } onCancel: { policy.cancel(task) }
    }
}

final class NewsletterHTTPPolicy: NSObject, URLSessionDataDelegate, Sendable {
    private let requests = Mutex<[Int: NewsletterHTTPPending]>([:])

    fileprivate func register(_ pending: NewsletterHTTPPending, for task: URLSessionTask) {
        requests.withLock { $0[task.taskIdentifier] = pending }
    }

    fileprivate func cancel(_ task: URLSessionTask) {
        finish(task, result: .failure(CancellationError()))
        task.cancel()
    }

    private func finish(_ task: URLSessionTask, result: Result<Void, any Error>) {
        let pending = requests.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        pending?.finish(result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let result: Result<Void, any Error>
        if let http = response as? HTTPURLResponse {
            result = (200..<300).contains(http.statusCode)
                ? .success(()) : .failure(NewsletterTransportError.refused(http.statusCode))
        } else { result = .failure(NewsletterTransportError.invalidResponse) }
        finish(dataTask, result: result)
        // The server's status is authoritative for this request. Never read,
        // render or buffer its response body, even when the sender leaves it open.
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(task, result: .failure(error ?? NewsletterTransportError.invalidResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // TLS uses the system's trust evaluation. HTTP/proxy credentials and
        // client certificates are never supplied to unsubscribe endpoints.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

private final class NewsletterHTTPPending: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var result: Result<Void, any Error>?
    }
    private let state = Mutex(State())

    func wait(_ continuation: CheckedContinuation<Void, any Error>) {
        let result = state.withLock { state -> Result<Void, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<Void, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(with: result)
    }
}

enum NewsletterNetworkPolicy {
    static func isPublicHost(_ host: String) -> Bool {
        publicAddresses(host) != nil
    }

    static func publicAddresses(_ host: String) -> [String]? {
        guard NewsletterURLPolicy.isPublicHostname(host) else { return nil }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var addresses: [String] = []
        while let item = cursor {
            guard let address = item.pointee.ai_addr else { return nil }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
                guard isPublicIPv4(value) else { return nil }
            case AF_INET6:
                let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                guard withUnsafeBytes(of: value, { isPublicIPv6(Array($0)) }) else { return nil }
            default: return nil
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, item.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            addresses.append(String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
            cursor = item.pointee.ai_next
        }
        return addresses.isEmpty ? nil : addresses
    }

    static func isPublicNumericAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 { return isPublicIPv4(ipv4.s_addr.bigEndian) }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            return withUnsafeBytes(of: ipv6) { isPublicIPv6(Array($0)) }
        }
        return false
    }

    static func isPublicIPv4(_ value: UInt32) -> Bool {
        let a = value >> 24, b = (value >> 16) & 255, c = (value >> 8) & 255
        return a != 0 && a != 10 && a != 127 && a < 224
            && !(a == 100 && (64...127).contains(b))
            && !(a == 169 && b == 254) && !(a == 172 && (16...31).contains(b))
            && !(a == 192 && (b == 168 || b == 0)) && !(a == 198 && (b == 18 || b == 19))
            // These IANA special-purpose blocks are not general web origins.
            && !(a == 192 && ((b == 31 && c == 196) || (b == 52 && c == 193)
                             || (b == 88 && c == 99) || (b == 175 && c == 48)))
            && !(a == 198 && b == 51 && c == 100) && !(a == 203 && b == 0 && c == 113)
    }

    static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        // Global unicast, excluding mapped IPv4, NAT64, 6to4, Teredo and
        // documentation ranges. All DNS answers must pass, not just one.
        bytes.count == 16 && (bytes[0] & 0xe0) == 0x20
            && !(bytes[0] == 0x20 && bytes[1] == 0x02)
            && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2)
            && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
            && !(bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0)
    }
}
