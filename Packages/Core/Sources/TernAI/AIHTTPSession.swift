import Foundation
import Synchronization

/// Keeps connections available across model calls while cancellation stays local to one request.
final class AIHTTPSession: Sendable {
    private let delegate: AIHTTPDelegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        let delegate = AIHTTPDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    var transport: AIHTTPTransport {
        AIHTTPTransport { request in try await self.send(request) }
    }

    private func send(_ request: URLRequest) async throws -> AIHTTPResponse {
        let task = session.dataTask(with: request)
        let pending = AIHTTPPendingRequest()
        delegate.register(pending, for: task)
        pending.bodyContinuation.onTermination = { [delegate] _ in delegate.cancel(task) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.waitForHeaders(continuation)
                task.resume()
            }
        } onCancel: { [delegate] in delegate.cancel(task) }
    }
}

private final class AIHTTPDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let requests = Mutex<[Int: AIHTTPPendingRequest]>([:])

    func register(_ request: AIHTTPPendingRequest, for task: URLSessionTask) {
        requests.withLock { $0[task.taskIdentifier] = request }
    }

    func cancel(_ task: URLSessionTask) {
        fail(task, error: CancellationError())
    }

    private func fail(_ task: URLSessionTask, error: any Error) {
        let pending = requests.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        pending?.finish(error: error)
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let pending = requests.withLock({ $0[dataTask.taskIdentifier] }) else {
            completionHandler(.cancel)
            return
        }
        guard let response = response as? HTTPURLResponse else {
            fail(dataTask, error: AIProviderError.malformedResponse(.httpResponse))
            completionHandler(.cancel)
            return
        }
        let delivered = pending.receiveHeaders(AIHTTPResponse(status: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"), body: pending.body,
            cancel: { [self] in cancel(dataTask) }))
        completionHandler(delivered ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let pending = requests.withLock({ $0[dataTask.taskIdentifier] }) else { return }
        // Delegate callbacks have variable sizes. Each queued element is at most
        // 1 KiB, retaining the transport's 2 MiB maximum waiting for its parser.
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: min(1024, data.distance(from: offset, to: data.endIndex)))
            switch pending.bodyContinuation.yield(Data(data[offset..<end])) {
            case .enqueued: break
            case .dropped:
                fail(dataTask, error: AIProviderError.responseLimit)
                return
            case .terminated:
                cancel(dataTask)
                return
            @unknown default:
                fail(dataTask, error: AIProviderError.streamInterrupted)
                return
            }
            offset = end
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let pending = requests.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        pending?.finish(error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class AIHTTPPendingRequest: Sendable {
    private enum Headers {
        case pending
        case waiting(CheckedContinuation<AIHTTPResponse, any Error>)
        case delivered
        case failed(any Error)
    }
    private let headers = Mutex<Headers>(.pending)
    let body: AsyncThrowingStream<Data, any Error>
    let bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation

    init() {
        (body, bodyContinuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(2048))
    }

    func waitForHeaders(_ continuation: CheckedContinuation<AIHTTPResponse, any Error>) {
        let error: (any Error)? = headers.withLock { state in
            if case .failed(let error) = state { return error }
            state = .waiting(continuation)
            return nil
        }
        if let error { continuation.resume(throwing: error) }
    }

    func receiveHeaders(_ response: AIHTTPResponse) -> Bool {
        let continuation = headers.withLock { state -> CheckedContinuation<AIHTTPResponse, any Error>? in
            guard case .waiting(let continuation) = state else { return nil }
            state = .delivered
            return continuation
        }
        continuation?.resume(returning: response)
        return continuation != nil
    }

    func finish(error: (any Error)?) {
        let continuation = headers.withLock { state -> CheckedContinuation<AIHTTPResponse, any Error>? in
            let continuation: CheckedContinuation<AIHTTPResponse, any Error>?
            if case .waiting(let waiting) = state { continuation = waiting } else { continuation = nil }
            if case .delivered = state {} else { state = .failed(error ?? AIProviderError.malformedResponse(.httpResponse)) }
            return continuation
        }
        continuation?.resume(throwing: error ?? AIProviderError.malformedResponse(.httpResponse))
        bodyContinuation.finish(throwing: error)
    }
}
