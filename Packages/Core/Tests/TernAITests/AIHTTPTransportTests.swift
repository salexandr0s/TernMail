import Foundation
import Synchronization
import Testing
@testable import TernAI

@Suite(.timeLimit(.minutes(1))) struct AIHTTPTransportTests {
    @Test func deliversBodyBeforeCompletionAndKeepsRequestHeadersIndependent() async throws {
        let fixture = try HTTPFixture()
        var request = fixture.request
        request.setValue("Bearer first", forHTTPHeaderField: "Authorization")
        let opening = Task { try await fixture.transport.send(request) }
        await fixture.endpoint.started()
        fixture.endpoint.respond()
        let response = try await opening.value
        #expect(response.status == 200)
        #expect(response.contentType == "text/event-stream")
        fixture.endpoint.emit(Data("first".utf8))
        var iterator = response.body.makeAsyncIterator()
        #expect(try await iterator.next() == Data("first".utf8))
        fixture.endpoint.emit(Data("second".utf8))
        fixture.endpoint.complete()
        #expect(try await iterator.next() == Data("second".utf8))
        #expect(try await iterator.next() == nil)

        let next = try HTTPFixture(transport: fixture.transport)
        var nextRequest = next.request
        nextRequest.setValue("Bearer second", forHTTPHeaderField: "Authorization")
        let nextOpening = Task { try await next.transport.send(nextRequest) }
        await next.endpoint.started()
        #expect(next.endpoint.request?.value(forHTTPHeaderField: "Authorization") == "Bearer second")
        #expect(next.endpoint.request?.value(forHTTPHeaderField: "Cookie") == nil)
        next.endpoint.respond()
        next.endpoint.complete()
        _ = try await nextOpening.value
    }

    @Test func cancellationBeforeHeadersDoesNotWaitForProvider() async throws {
        let fixture = try HTTPFixture()
        let opening = Task { try await fixture.transport.send(fixture.request) }
        await fixture.endpoint.started()
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        await fixture.endpoint.stopped()

        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.transport.send(fixture.request)
        }
        await #expect(throws: CancellationError.self) { try await alreadyCancelled.value }
    }

    @Test func cancellingOneResponsePreservesOtherRequestsAndLaterCalls() async throws {
        let first = try HTTPFixture()
        let second = try HTTPFixture(transport: first.transport)
        let firstOpening = Task { try await first.transport.send(first.request) }
        let secondOpening = Task { try await second.transport.send(second.request) }
        await first.endpoint.started()
        await second.endpoint.started()
        first.endpoint.respond()
        second.endpoint.respond()
        let firstResponse = try await firstOpening.value
        let secondResponse = try await secondOpening.value
        firstResponse.cancel()
        await #expect(throws: CancellationError.self) { try await Self.collect(firstResponse.body) }
        await first.endpoint.stopped()
        second.endpoint.emit(Data("unaffected".utf8))
        second.endpoint.complete()
        #expect(try await Self.collect(secondResponse.body) == Data("unaffected".utf8))

        let third = try HTTPFixture(transport: first.transport)
        let thirdOpening = Task { try await third.transport.send(third.request) }
        await third.endpoint.started()
        third.endpoint.respond()
        third.endpoint.emit(Data("later".utf8))
        third.endpoint.complete()
        let thirdResponse = try await thirdOpening.value
        #expect(try await Self.collect(thirdResponse.body) == Data("later".utf8))
    }

    @Test func cancellingBodyIterationStopsOnlyItsTask() async throws {
        let fixture = try HTTPFixture()
        let opening = Task { try await fixture.transport.send(fixture.request) }
        await fixture.endpoint.started()
        fixture.endpoint.respond()
        let response = try await opening.value
        let reading = Task { try await Self.collect(response.body) }
        reading.cancel()
        _ = try? await reading.value
        await fixture.endpoint.stopped()
    }

    @Test(arguments: [false, true])
    func propagatesFailuresBeforeAndAfterHeaders(afterHeaders: Bool) async throws {
        let fixture = try HTTPFixture()
        let opening = Task { try await fixture.transport.send(fixture.request) }
        await fixture.endpoint.started()
        if afterHeaders {
            fixture.endpoint.respond()
            let response = try await opening.value
            fixture.endpoint.emit(Data("partial".utf8))
            fixture.endpoint.fail(URLError(.networkConnectionLost))
            var iterator = response.body.makeAsyncIterator()
            #expect(try await iterator.next() == Data("partial".utf8))
            await #expect(throws: URLError.self) { try await iterator.next() }
        } else {
            fixture.endpoint.fail(URLError(.networkConnectionLost))
            await #expect(throws: URLError.self) { try await opening.value }
        }
    }

    @Test func boundsBufferedBytesAcrossLargeDelegateCallbacks() async throws {
        let fixture = try HTTPFixture()
        let opening = Task { try await fixture.transport.send(fixture.request) }
        await fixture.endpoint.started()
        fixture.endpoint.respond()
        let response = try await opening.value
        fixture.endpoint.emit(Data(repeating: 65, count: 2_097_153))
        await fixture.endpoint.stopped()
        var byteCount = 0
        do {
            for try await chunk in response.body {
                #expect(chunk.count <= 1024)
                byteCount += chunk.count
            }
            Issue.record("Expected the stalled consumer's buffer to be bounded")
        } catch { #expect(error as? AIProviderError == .responseLimit) }
        #expect(byteCount == 2_097_152)
    }

    @Test func rejectsNonHTTPResponses() async throws {
        let fixture = try HTTPFixture()
        let opening = Task { try await fixture.transport.send(fixture.request) }
        await fixture.endpoint.started()
        fixture.endpoint.respond(http: false)
        await #expect(throws: AIProviderError.malformedResponse(.httpResponse)) { try await opening.value }
        await fixture.endpoint.stopped()
    }

    private static func collect(_ body: AsyncThrowingStream<Data, any Error>) async throws -> Data {
        var result = Data()
        for try await chunk in body { result.append(chunk) }
        return result
    }
}

private final class HTTPFixture: Sendable {
    let endpoint = HTTPTestEndpoint()
    let request: URLRequest
    let transport: AIHTTPTransport
    private let id = UUID().uuidString

    init(transport: AIHTTPTransport? = nil) throws {
        request = URLRequest(url: try #require(URL(string: "https://transport.invalid/\(id)")))
        if let transport { self.transport = transport }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HTTPTestProtocol.self]
            self.transport = AIHTTPSession(configuration: configuration).transport
        }
        HTTPTestProtocol.endpoints.withLock { $0[id] = endpoint }
    }

    deinit { HTTPTestProtocol.endpoints.withLock { _ = $0.removeValue(forKey: id) } }
}

// Foundation owns protocol callbacks; all mutable test state lives in the endpoint's Mutex.
private final class HTTPTestProtocol: URLProtocol, @unchecked Sendable {
    static let endpoints = Mutex<[String: HTTPTestEndpoint]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { endpoint?.start(self) }
    override func stopLoading() { endpoint?.stop() }

    private var endpoint: HTTPTestEndpoint? {
        Self.endpoints.withLock { $0[request.url?.lastPathComponent ?? ""] }
    }
}

private final class HTTPTestEndpoint: Sendable {
    private struct State {
        var connection: HTTPTestProtocol?
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

    func start(_ connection: HTTPTestProtocol) {
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

    func respond(http: Bool = true) {
        guard let connection = state.withLock({ $0.connection }), let url = connection.request.url else { return }
        let response: URLResponse
        if http, let value = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) { response = value }
        else { response = URLResponse(url: url, mimeType: "text/event-stream", expectedContentLength: -1, textEncodingName: nil) }
        connection.client?.urlProtocol(connection, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func emit(_ data: Data) {
        guard let connection = state.withLock({ $0.connection }) else { return }
        connection.client?.urlProtocol(connection, didLoad: data)
    }

    func complete() {
        guard let connection = state.withLock({ $0.connection }) else { return }
        connection.client?.urlProtocolDidFinishLoading(connection)
    }

    func fail(_ error: any Error) {
        guard let connection = state.withLock({ $0.connection }) else { return }
        connection.client?.urlProtocol(connection, didFailWithError: error)
    }
}
