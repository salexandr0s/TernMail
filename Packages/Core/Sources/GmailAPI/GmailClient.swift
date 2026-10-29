import Foundation

/// Supplies OAuth access tokens. The app implements it with AppAuth, so this
/// package never depends on an auth library.
public protocol AccessTokenProvider: Sendable {
    /// Returns a usable access token. `forceRefresh` asks for a new one after
    /// the server rejected the current token.
    func accessToken(forceRefresh: Bool) async throws -> String
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GmailError.transport(.badServerResponse)
        }
        return (data, http)
    }
}

/// Client for the parts of the Gmail REST API the app uses. Calls that take
/// several IDs go through `/batch` and report a result per ID.
public struct GmailClient: Sendable {
    /// Calls per `/batch` request. Google accepts 100; 25 `messages.get` calls
    /// stay under Gmail's per-user rate limit.
    static let batchSize = 25
    /// `messages.batchModify` accepts at most 1,000 IDs.
    static let batchModifyLimit = 1000

    private let tokens: any AccessTokenProvider
    private let transport: any HTTPTransport
    private let retryDelays: [Duration]

    /// - Parameter retryDelays: Waits before resending `/batch` parts that failed
    ///   with a retryable status. One retry round per delay.
    public init(
        tokens: any AccessTokenProvider,
        transport: any HTTPTransport = URLSession.shared,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    ) {
        self.tokens = tokens
        self.transport = transport
        self.retryDelays = retryDelays
    }

    // MARK: Reads

    public func profile() async throws -> GmailProfile {
        try decode(await send(.get("profile")))
    }

    public func labels() async throws -> [GmailLabel] {
        let list: LabelList = try decode(await send(.get("labels")))
        return list.labels ?? []
    }

    /// `labels.get` for each ID, which unlike `labels.list` includes counts.
    public func labels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>] {
        try await batchDecode(ids) { .get("labels/\($0)") }
    }

    public func listMessages(
        query: String? = nil,
        labelIDs: [String] = [],
        includeSpamTrash: Bool = false,
        pageToken: String? = nil,
        maxResults: Int = 500
    ) async throws -> MessageListPage {
        var items = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        items += labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
        if includeSpamTrash { items.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try decode(await send(.get("messages", items)))
    }

    public func messages(
        ids: [String],
        format: MessageFormat,
        metadataHeaders: [String] = []
    ) async throws -> [String: Result<GmailMessage, GmailError>] {
        var items = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata {
            items += metadataHeaders.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        }
        return try await batchDecode(ids) { .get("messages/\($0)", items) }
    }

    public func thread(id: String, format: MessageFormat = .full) async throws -> GmailThread {
        try decode(await send(.get("threads/\(id)", [URLQueryItem(name: "format", value: format.rawValue)])))
    }

    /// The bytes of a part Gmail stores outside the payload: an attachment, or
    /// sometimes a readable text part. `attachmentID` is the part's `body.attachmentId`.
    public func attachment(messageID: String, attachmentID: String) async throws -> Data {
        let body: MessagePart.Body = try decode(await send(.get("messages/\(messageID)/attachments/\(attachmentID)")))
        guard let data = body.decodedData else { throw GmailError.decoding("Message part data") }
        return data
    }

    /// One page of `history.list`. Gmail answers 404 when `startHistoryID` is too old.
    public func history(startHistoryID: String, pageToken: String? = nil) async throws -> HistoryPage {
        var items = [
            URLQueryItem(name: "startHistoryId", value: startHistoryID),
            URLQueryItem(name: "maxResults", value: "500"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try decode(await send(.get("history", items)))
    }

    // MARK: Changes

    /// Adds and removes labels on whole threads, including messages outside the
    /// local cache. Returns the threads that failed.
    public func modifyThreads(
        ids: [String],
        addLabelIDs: [String],
        removeLabelIDs: [String]
    ) async throws -> [String: GmailError] {
        let body = try encode(LabelChangeRequest(addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs))
        return try await batchFailures(ids) { .post("threads/\($0)/modify", body: body) }
    }

    public func trashThreads(ids: [String]) async throws -> [String: GmailError] {
        try await batchFailures(ids) { .post("threads/\($0)/trash") }
    }

    public func untrashThreads(ids: [String]) async throws -> [String: GmailError] {
        try await batchFailures(ids) { .post("threads/\($0)/untrash") }
    }

    public func batchModifyMessages(
        ids: [String],
        addLabelIDs: [String],
        removeLabelIDs: [String]
    ) async throws {
        for chunk in ids.chunked(into: Self.batchModifyLimit) {
            let body = try encode(BatchModifyRequest(
                ids: Array(chunk),
                addLabelIds: addLabelIDs,
                removeLabelIds: removeLabelIDs
            ))
            _ = try await send(.post("messages/batchModify", body: body))
        }
    }

    // MARK: Transport

    func send(_ endpoint: Endpoint) async throws -> Data {
        try await send(endpoint.urlRequest()).data
    }

    /// Sends a request with a bearer token. A 401 is retried once with a
    /// forced token refresh; any other non-2xx status throws.
    func send(_ request: URLRequest, forceRefresh initiallyForced: Bool = false) async throws -> (data: Data, response: HTTPURLResponse) {
        var forceRefresh = initiallyForced
        while true {
            var authorized = request
            let token = try await tokens.accessToken(forceRefresh: forceRefresh)
            try Task.checkCancellation()
            authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await perform(authorized)
            if (200..<300).contains(response.statusCode) {
                return (data, response)
            }
            if response.statusCode == 401, !forceRefresh {
                forceRefresh = true
                continue
            }
            throw GmailError(status: response.statusCode, body: data)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw GmailError.transport(error.code)
        }
    }

    /// Sends `endpoints` through `/batch`, `batchSize` at a time and one batch at
    /// a time, and returns one result per endpoint in input order. Parts that
    /// fail with a retryable status are resent after each delay in `retryDelays`.
    private func batch(_ endpoints: [Endpoint]) async throws -> [Result<Data, GmailError>] {
        var results = [Result<Data, GmailError>](repeating: .failure(.missingBatchPart), count: endpoints.count)
        var pending = Array(endpoints.indices)
        var delays = retryDelays[...]
        while !pending.isEmpty {
            var retry: [Int] = []
            for chunk in pending.chunked(into: Self.batchSize) {
                let parts = try await sendBatch(chunk.map { endpoints[$0] })
                for (index, result) in zip(chunk, parts) {
                    results[index] = result
                    if case .failure(let error) = result, error.isRetryable {
                        retry.append(index)
                    }
                }
            }
            guard !retry.isEmpty, let delay = delays.popFirst() else { break }
            try await Task.sleep(for: delay)
            pending = retry
        }
        return results
    }

    private func sendBatch(_ endpoints: [Endpoint], forceRefresh: Bool = false) async throws -> [Result<Data, GmailError>] {
        let boundary = "tern-\(UUID().uuidString)"
        var request = try Endpoint.batchRequest()
        request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try BatchCodec.encode(endpoints, boundary: boundary)

        let (data, response) = try await send(request, forceRefresh: forceRefresh)
        guard let responseBoundary = BatchCodec.boundary(contentType: response.value(forHTTPHeaderField: "Content-Type")) else {
            throw GmailError.decoding("Batch response has no boundary")
        }
        var partsByIndex: [Int: BatchCodec.Part] = [:]
        for part in try BatchCodec.decode(data, boundary: responseBoundary) {
            if let index = part.itemIndex { partsByIndex[index] = part }
        }
        var results: [Result<Data, GmailError>] = endpoints.indices.map { index in
            guard let part = partsByIndex[index] else { return .failure(.missingBatchPart) }
            guard (200..<300).contains(part.status) else {
                return .failure(GmailError(status: part.status, body: part.body))
            }
            return .success(part.body)
        }
        if !forceRefresh {
            let unauthorized = results.indices.filter {
                if case .failure(.unauthorized) = results[$0] { return true }
                return false
            }
            if !unauthorized.isEmpty {
                let refreshed = try await sendBatch(unauthorized.map { endpoints[$0] }, forceRefresh: true)
                for (index, result) in zip(unauthorized, refreshed) { results[index] = result }
            }
        }
        return results
    }

    private func batchDecode<T: Decodable & Sendable>(
        _ ids: [String],
        endpoint: (String) -> Endpoint
    ) async throws -> [String: Result<T, GmailError>] {
        let unique = ids.uniqued()
        let results = try await batch(unique.map(endpoint))
        var decoded: [String: Result<T, GmailError>] = [:]
        for (id, result) in zip(unique, results) {
            switch result {
            case .success(let data):
                decoded[id] = Result { try decode(data) as T }.mapError { $0 as? GmailError ?? .decoding("\(T.self)") }
            case .failure(let error):
                decoded[id] = .failure(error)
            }
        }
        return decoded
    }

    private func batchFailures(_ ids: [String], endpoint: (String) -> Endpoint) async throws -> [String: GmailError] {
        let unique = ids.uniqued()
        let results = try await batch(unique.map(endpoint))
        var failures: [String: GmailError] = [:]
        for (id, result) in zip(unique, results) {
            if case .failure(let error) = result { failures[id] = error }
        }
        return failures
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GmailError.decoding("\(T.self)")
        }
    }

    func encode(_ value: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw GmailError.invalidRequest("Could not encode request body")
        }
    }
}

private struct LabelChangeRequest: Encodable {
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

private struct BatchModifyRequest: Encodable {
    let ids: [String]
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

/// One Gmail API call, relative to `/gmail/v1/users/me/`, or to
/// `/upload/gmail/v1/users/me/` for calls that upload a message.
struct Endpoint: Sendable {
    enum Base: String, Sendable {
        case api = "/gmail/v1/users/me/"
        case upload = "/upload/gmail/v1/users/me/"
    }

    static let host = "gmail.googleapis.com"

    var base = Base.api
    let method: String
    let path: String
    let query: [URLQueryItem]
    let body: Data?
    var contentType = "application/json"
    var headers: [String: String] = [:]

    static func get(_ path: String, _ query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: "GET", path: path, query: query, body: nil)
    }

    static func post(_ path: String, body: Data? = nil) -> Endpoint {
        Endpoint(method: "POST", path: path, query: [], body: body)
    }

    static func delete(_ path: String) -> Endpoint {
        Endpoint(method: "DELETE", path: path, query: [], body: nil)
    }

    static func batchRequest() throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/batch/gmail/v1"
        guard let url = components.url else { throw GmailError.invalidRequest("batch") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        return request
    }

    func components() -> URLComponents {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = base.rawValue + path
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves "+" as is, and Google decodes it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        return components
    }

    func urlRequest() throws -> URLRequest {
        guard let url = components().url else { throw GmailError.invalidRequest(path) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// The percent-encoded path and query, as written in a batch part's request line.
    func requestTarget() throws -> String {
        let components = components()
        guard components.url != nil else { throw GmailError.invalidRequest(path) }
        if let query = components.percentEncodedQuery {
            return components.percentEncodedPath + "?" + query
        }
        return components.percentEncodedPath
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

extension Array where Element: Hashable {
    /// The elements in order, without repeats.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
