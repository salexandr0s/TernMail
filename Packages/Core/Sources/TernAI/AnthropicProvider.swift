import Foundation

/// Claude's Messages API, using an API key supplied by the app's connection store.
public struct AnthropicProvider: AIProvider {
    private let apiKey: @Sendable () async throws -> String
    private let transport: AIHTTPTransport
    private let requestTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(apiKey: @escaping @Sendable () async throws -> String,
                transport: AIHTTPTransport = .live, requestTimeout: Duration = .seconds(120)) {
        self.init(apiKey: apiKey, transport: transport, requestTimeout: requestTimeout,
                  sleep: { try await Task.sleep(for: $0) })
    }

    init(apiKey: @escaping @Sendable () async throws -> String, transport: AIHTTPTransport,
         requestTimeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.apiKey = apiKey; self.transport = transport; self.requestTimeout = requestTimeout
        self.sleep = sleep
    }

    public func models() async throws -> [AIModel] {
        do { return try await deadline { try await catalogue() } }
        catch {
            if error as? AIProviderError == .responseLimit { throw AIProviderError.catalogueLimit }
            throw sanitized(error)
        }
    }

    private func catalogue() async throws -> [AIModel] {
        var result: [AIModel] = []
        var seen: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        var bytes = 0
        for _ in 0..<10 {
            var query = [URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "after_id", value: cursor)) }
            let request = try await authorizedRequest(path: "models", method: "GET", query: query)
            let response = try await transport.send(request)
            defer { response.cancel() }
            try await checkStatus(response)
            try contentType(response, expected: "application/json")
            let data = try await collect(response.body, limit: 2_097_152 - bytes)
            bytes += data.count
            let value = try AIJSON.decode(data)
            guard let entries = value["data"]?.arrayValue, let hasMore = value["has_more"]?.boolValue else {
                throw AIProviderError.invalidResponse
            }
            guard entries.count <= 100, seen.count + entries.count <= 1_000 else { throw AIProviderError.catalogueLimit }
            for entry in entries {
                guard entry["type"]?.stringValue == "model",
                      let id = entry["id"]?.stringValue, AnthropicRequest.identifier(id),
                      let name = entry["display_name"]?.stringValue, !name.isEmpty, name.utf8.count <= 256,
                      seen.insert(id).inserted else { throw AIProviderError.invalidResponse }
                guard entry["lifecycle"]?.stringValue != "retired",
                      entry["capabilities"]?["structured_outputs"]?["supported"]?.boolValue == true else { continue }
                result.append(AIModel(id: id, displayName: name,
                    supportsImages: entry["capabilities"]?["image_input"]?["supported"]?.boolValue == true))
            }
            if !hasMore { return result }
            guard !entries.isEmpty, let last = value["last_id"]?.stringValue,
                  last == entries.last?["id"]?.stringValue, cursors.insert(last).inserted else {
                throw AIProviderError.invalidResponse
            }
            cursor = last
        }
        throw AIProviderError.catalogueLimit
    }

    public func respond(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(4096)) { continuation in
            let task = Task {
                do {
                    try await deadline { try await consume(request, continuation: continuation) }
                    continuation.finish()
                } catch { continuation.finish(throwing: sanitized(error)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consume(_ request: AIRequest, continuation: AsyncThrowingStream<AIEvent, any Error>.Continuation) async throws {
        let body = try AnthropicRequest.encode(request)
        var http = try await authorizedRequest(path: "messages", method: "POST")
        http.httpBody = body
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let response = try await transport.send(http)
        defer { response.cancel() }
        try await checkStatus(response)
        try contentType(response, expected: "text/event-stream")
        var decoder = SSEDecoder()
        var stream = AnthropicStream(tools: request.tools)
        for try await chunk in response.body {
            try Task.checkCancellation()
            for event in try decoder.append(chunk) {
                for item in try stream.accept(event) {
                    try Task.checkCancellation()
                    switch continuation.yield(item) {
                    case .enqueued: break
                    case .dropped: throw AIProviderError.responseLimit
                    case .terminated: throw CancellationError()
                    @unknown default: throw AIProviderError.streamInterrupted
                    }
                    if case .completed = item { return }
                }
            }
        }
        try decoder.finish()
        throw AIProviderError.streamInterrupted
    }

    private func authorizedRequest(path: String, method: String, query: [URLQueryItem] = []) async throws -> URLRequest {
        let key = try await apiKey()
        try Task.checkCancellation()
        guard !key.isEmpty, key.utf8.count <= 16_384, key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              var components = URLComponents(string: "https://api.anthropic.com/v1/\(path)") else {
            throw AIProviderError.apiKeyRequired
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AIProviderError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        return request
    }

    private func checkStatus(_ response: AIHTTPResponse) async throws {
        guard !(200..<300).contains(response.status) else { return }
        let body = try? await collect(response.body, limit: 8192)
        let kind = body.flatMap { try? AIJSON.decode($0) }?["error"]?["type"]?.stringValue
        switch response.status {
        case 401: throw AIProviderError.apiKeyRequired
        case 402: throw AIProviderError.insufficientCredits
        case 403: throw AIProviderError.accessDenied
        case 413: throw AIProviderError.invalidRequest
        case 429: throw AIProviderError.rateLimited
        case 500...599: throw AIProviderError.unavailable
        default: throw AIProviderError.httpRejected(status: response.status,
            code: Self.errorIdentifier(kind), parameter: nil)
        }
    }

    static func streamError(_ value: AIJSON?) -> AIProviderError {
        switch value?["type"]?.stringValue {
        case "authentication_error": .apiKeyRequired
        case "permission_error": .accessDenied
        case "rate_limit_error": .rateLimited
        case "invalid_request_error", "request_too_large": .invalidRequest
        default: .unavailable
        }
    }

    private static func errorIdentifier(_ text: String?) -> String? {
        guard let text, text.utf8.count <= 96,
              text.range(of: #"\A[a-z][a-z_]*\z"#, options: .regularExpression) != nil else { return nil }
        return text
    }

    private func contentType(_ response: AIHTTPResponse, expected: String) throws {
        guard response.contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() == expected else {
            throw AIProviderError.malformedResponse(.contentType)
        }
    }

    private func collect(_ body: AsyncThrowingStream<Data, any Error>, limit: Int) async throws -> Data {
        var result = Data()
        for try await chunk in body {
            try Task.checkCancellation()
            guard chunk.count <= limit - result.count else { throw AIProviderError.responseLimit }
            result.append(chunk)
        }
        return result
    }

    private func sanitized(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? AIProviderError { return error }
        if let error = error as? URLError, error.code == .timedOut { return AIProviderError.timedOut }
        if error is DecodingError { return AIProviderError.malformedResponse(.jsonDecoding) }
        return AIProviderError.network
    }

    private func deadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await sleep(requestTimeout); throw AIProviderError.timedOut }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
