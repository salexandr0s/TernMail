import Foundation
import Synchronization
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1))) struct NewsletterTransportTests {
    @Test func postsExactFormWithoutContext() async throws {
        let fixture = try NewsletterHTTPFixture()
        let send = Task { try await fixture.transport.unsubscribe(at: fixture.url) }
        await fixture.endpoint.started()
        let request = try #require(fixture.endpoint.request)
        #expect(request.url == fixture.url)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
        #expect(!request.httpShouldHandleCookies)
        let body: Data
        if let bytes = request.httpBody { body = bytes }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = stream.read(&buffer, maxLength: buffer.count)
            body = Data(buffer.prefix(max(0, count)))
        } else { body = Data() }
        #expect(body == Data("List-Unsubscribe=One-Click".utf8))
        fixture.endpoint.respond(status: 204)
        try await send.value
        await fixture.endpoint.stopped()
    }

    @Test(arguments: [301, 302, 307, 308, 400, 401, 429, 500])
    func nonSuccessIsNeverReportedAsUnsubscribed(status: Int) async throws {
        let fixture = try NewsletterHTTPFixture()
        let send = Task { try await fixture.transport.unsubscribe(at: fixture.url) }
        await fixture.endpoint.started()
        fixture.endpoint.respond(status: status)
        await #expect(throws: NewsletterTransportError.refused(status)) { try await send.value }
        await fixture.endpoint.stopped()
    }

    @Test func cancellationBeforeHeadersStopsTheRequest() async throws {
        let fixture = try NewsletterHTTPFixture()
        let send = Task { try await fixture.transport.unsubscribe(at: fixture.url) }
        await fixture.endpoint.started()
        send.cancel()
        do { try await send.value; Issue.record("Canceled request returned success") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        await fixture.endpoint.stopped()
    }

    @Test func rejectsUnsafeEndpointsBeforeTransportAndDNS() async throws {
        let called = Mutex(false)
        let client = NewsletterHTTPSession(configuration: .ephemeral) { _ in called.withLock { $0 = true } }
        for raw in ["http://news.example.com/unsub", "https://localhost/unsub", "https://127.0.0.1/unsub",
                    "https://news.example.com:8443/unsub", "https://user:pass@news.example.com/unsub"] {
            let url = try #require(URL(string: raw))
            await #expect(throws: NewsletterTransportError.unsafeURL) { try await client.unsubscribe(at: url) }
        }
        #expect(!called.withLock { $0 })
    }

    @Test func DNSDeadlineAndCancellationDoNotWaitForTheResolver() async throws {
        do {
            try await NewsletterDNSCheck.validate(timeout: 0.01) { Thread.sleep(forTimeInterval: 0.1); return true }
            Issue.record("Expected the DNS deadline")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        let resolving = Task {
            try await NewsletterDNSCheck.validate { Thread.sleep(forTimeInterval: 0.1); return true }
        }
        resolving.cancel()
        await #expect(throws: CancellationError.self) { try await resolving.value }
    }

    @Test func publicAddressChecksRejectPrivateAndSpecialNetworks() {
        for parts in [[0, 0, 0, 0], [10, 0, 0, 1], [127, 0, 0, 1], [169, 254, 1, 1], [172, 16, 1, 1],
                      [192, 168, 1, 1], [100, 64, 1, 1], [198, 18, 0, 1], [192, 0, 2, 1],
                      [198, 51, 100, 1], [203, 0, 113, 1], [224, 0, 0, 1], [255, 255, 255, 255]] {
            let value = parts.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            #expect(!NewsletterNetworkPolicy.isPublicIPv4(value))
        }
        #expect(NewsletterNetworkPolicy.isPublicIPv4(0x08080808))
        for parts in [[192, 31, 196, 1], [192, 52, 193, 1], [192, 88, 99, 2], [192, 175, 48, 1]] {
            let value = parts.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            #expect(!NewsletterNetworkPolicy.isPublicIPv4(value))
        }
        #expect(!NewsletterNetworkPolicy.isPublicIPv6(Array(repeating: 0, count: 16)))
        #expect(!NewsletterNetworkPolicy.isPublicIPv6([0xfc] + Array(repeating: 0, count: 15)))
        #expect(!NewsletterNetworkPolicy.isPublicIPv6([0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 12)))
        #expect(!NewsletterNetworkPolicy.isPublicIPv6([0x3f, 0xff, 0x00, 0x01] + Array(repeating: 0, count: 12)))
        #expect(NewsletterNetworkPolicy.isPublicIPv6([0x26, 0x06, 0x47, 0x00] + Array(repeating: 0, count: 12)))
        for address in ["127.0.0.1", "10.0.0.1", "192.168.1.2", "::1", "fe80::1", "not-an-ip"] {
            #expect(!NewsletterNetworkPolicy.isPublicNumericAddress(address))
        }
        #expect(NewsletterNetworkPolicy.isPublicNumericAddress("8.8.8.8"))
        #expect(NewsletterNetworkPolicy.isPublicNumericAddress("2606:4700:4700::1111"))
    }

    @Test func pinnedTransportRejectsUncheckedAddressesBeforeConnecting() async throws {
        let url = try #require(URL(string: "https://news.example.com/unsubscribe"))
        let request = URLRequest(url: url)
        for address in ["127.0.0.1", "192.168.1.1", "::1", "news.example.com"] {
            await #expect(throws: NewsletterTransportError.unsafeURL) {
                try await PinnedNewsletterHTTP.post(request, address: address, hostname: "news.example.com")
            }
        }
    }

    @Test func pinnedRequestCarriesNoAmbientContextAndParsesInterimHeaders() throws {
        let url = try #require(URL(string: "https://news.example.com/unsubscribe?token=A%2fb+c"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let bytes = try PinnedNewsletterHTTP.requestBytes(components: components, hostname: "news.example.com",
            body: Data("List-Unsubscribe=One-Click".utf8))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("POST /unsubscribe?token=A%2fb+c HTTP/1.1\r\nHost: news.example.com\r\n"))
        #expect(text.contains("Content-Length: 26\r\n"))
        #expect(!text.contains("Authorization:"))
        #expect(!text.contains("Cookie:"))
        let response = Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n".utf8)
        let interim = try #require(try PinnedNewsletterHTTP.responseHeaders(in: response))
        #expect(interim.status == 100)
        let final = try #require(try PinnedNewsletterHTTP.responseHeaders(in: Data(response[interim.endIndex...])))
        #expect(final.status == 204)
        #expect(throws: NewsletterTransportError.invalidResponse) {
            try PinnedNewsletterHTTP.responseHeaders(in: Data("HTTP/1.1 20X Bad\r\n\r\n".utf8))
        }
    }

    @Test func pinnedImageLoaderRejectsPrivateHostsAndMalformedResponses() async throws {
        for url in ["https://127.0.0.1/image.png", "https://localhost/image.png", "https://service.internal/image.png"] {
            await #expect(throws: NewsletterTransportError.unsafeURL) {
                try await PinnedRemoteImageClient.load(URL(string: url)!)
            }
        }
        let good = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 3\r\n\r\nabc".utf8)
        let header = try #require(try PinnedRemoteImageClient.parseHeader(good))
        #expect(header.mimeType == "image/png")
        #expect(header.contentLength == 3)
        #expect(Data(good[header.bodyStart...]) == Data("abc".utf8))
        #expect(try PinnedRemoteImageClient.decodeChunked(Data("3\r\nabc\r\n0\r\n\r\n".utf8)) == Data("abc".utf8))
        for raw in [
            "HTTP/1.1 302 Found\r\nLocation: https://127.0.0.1/image.png\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: image/svg+xml\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 9000000\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: gzip\r\n\r\n",
        ] {
            #expect(throws: NewsletterTransportError.invalidResponse) {
                try PinnedRemoteImageClient.parseHeader(Data(raw.utf8))
            }
        }
    }

    @Test func imageDestinationRejectsMixedDNSAnswersAndPinsOneValidatedAddress() {
        #expect(PinnedRemoteImageClient.validatedAddress(["8.8.8.8", "1.1.1.1"]) == "8.8.8.8")
        for addresses in [[], ["8.8.8.8", "127.0.0.1"], ["8.8.8.8", "192.168.1.2"],
                          ["8.8.8.8", "::1"], ["example.com"]] {
            #expect(PinnedRemoteImageClient.validatedAddress(addresses) == nil)
        }
    }

    @Test func interimResponsesShareOneBoundedHeaderBudgetAcrossPackets() throws {
        let interim = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        var data = interim + Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\nabc".utf8)
        var consumed = 0
        #expect(try PinnedNewsletterHTTP.finalResponseHeaders(in: &data, consumedHeaderBytes: &consumed)?.status == 200)
        #expect(consumed == interim.count)
        #expect(try PinnedRemoteImageClient.parseHeader(data)?.mimeType == "image/png")
        #expect(throws: NewsletterTransportError.invalidResponse) {
            var bytes = Data()
            var total = 0
            for _ in 0..<1_024 {
                bytes.append(interim)
                _ = try PinnedNewsletterHTTP.finalResponseHeaders(in: &bytes, consumedHeaderBytes: &total)
            }
        }
    }

    @Test func chunkedImagesDecodeIncrementallyAcrossEveryFramingBoundary() throws {
        var decoder = PinnedRemoteImageClient.ChunkedDecoder()
        let encoded = Data("3;name=value\r\nabc\r\n2\r\nde\r\n0\r\nX-Info: ignored\r\n\r\n".utf8)
        var result: Data?
        for byte in encoded { result = try decoder.append(Data([byte])) }
        #expect(result == Data("abcde".utf8))
        for malformed in ["+3\r\nabc\r\n0\r\n\r\n", ";a\r\na\r\n0\r\n\r\n", "3\r\nabcXX", "800001\r\n"] {
            #expect(throws: NewsletterTransportError.invalidResponse) {
                try PinnedRemoteImageClient.decodeChunked(Data(malformed.utf8))
            }
        }
    }

    @Test func redirectDelegateAlwaysRefusesNewDestination() async throws {
        let policy = NewsletterHTTPPolicy()
        let url = try #require(URL(string: "https://news.example.com/unsub"))
        let target = try #require(URL(string: "https://other.example.com/unsub"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let accepted = await withCheckedContinuation { continuation in
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)) {
                continuation.resume(returning: $0)
            }
        }
        #expect(accepted == nil)
    }

    @Test func responseHeadersCancelBodyDeliveryWithoutWaitingForData() async throws {
        let policy = NewsletterHTTPPolicy()
        let url = try #require(URL(string: "https://news.example.com/unsub"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "99999999"]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        // URLProtocol buffers a synthetic response until didFinishLoading on
        // this OS. Exercise the actual delegate boundary without that buffer.
        let disposition = await withCheckedContinuation { continuation in
            policy.urlSession(session, dataTask: task, didReceive: response) {
                continuation.resume(returning: $0)
            }
        }
        #expect(disposition == .cancel)
    }
}

private final class NewsletterHTTPFixture: Sendable {
    let url: URL
    let transport: NewsletterHTTPSession
    let endpoint = NewsletterHTTPEndpoint()
    private let id = UUID().uuidString

    init() throws {
        url = try #require(URL(string: "https://newsletter.example.com/\(id)?token=A%2fb+c"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewsletterHTTPProtocol.self]
        transport = NewsletterHTTPSession(configuration: configuration, validateHost: { _ in })
        NewsletterHTTPProtocol.endpoints.withLock { $0[id] = endpoint }
    }

    deinit { NewsletterHTTPProtocol.endpoints.withLock { _ = $0.removeValue(forKey: id) } }
}

// Foundation owns protocol callbacks. Mutable test state is protected by the endpoint's Mutex.
private final class NewsletterHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let endpoints = Mutex<[String: NewsletterHTTPEndpoint]>([:])
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "newsletter.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { endpoint?.start(self) }
    override func stopLoading() { endpoint?.stop() }
    private var endpoint: NewsletterHTTPEndpoint? { Self.endpoints.withLock { $0[request.url?.lastPathComponent ?? ""] } }
}

private final class NewsletterHTTPEndpoint: Sendable {
    private struct State {
        var connection: NewsletterHTTPProtocol?
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var stopWaiters: [CheckedContinuation<Void, Never>] = []
        var didStop = false
    }
    private let state = Mutex(State())
    var request: URLRequest? { state.withLock { $0.connection?.request } }

    func started() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.connection != nil { return true }
                state.startWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func stopped() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.didStop { return true }
                state.stopWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func start(_ connection: NewsletterHTTPProtocol) {
        let waiters = state.withLock { state in
            state.connection = connection
            defer { state.startWaiters.removeAll() }
            return state.startWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func stop() {
        let waiters = state.withLock { state in
            state.didStop = true
            defer { state.stopWaiters.removeAll() }
            return state.stopWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func respond(status: Int) {
        guard let connection = state.withLock({ $0.connection }), let url = connection.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"]) else { return }
        connection.client?.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
        connection.client?.urlProtocolDidFinishLoading(connection)
    }
}
