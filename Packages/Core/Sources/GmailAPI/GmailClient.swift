import Foundation

/// Client for the parts of the Gmail REST API the app uses. Calls that take
/// several IDs go through `/batch` and report a result per ID.
public struct GmailClient: Sendable {
    /// Bound both concurrent parts and their quota cost. The account's shared
    /// budget also paces batches against direct Gmail requests.
    static let batchSize = 25
    /// `messages.batchModify` accepts at most 1,000 IDs.
    static let batchModifyLimit = 1000

    public let session: GoogleSession
    private let retryDelays: [Duration]

    /// - Parameter retryDelays: Waits before resending `/batch` parts that failed
    ///   with a retryable status. One retry round per delay.
    public init(session: GoogleSession, retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]) {
        self.session = session
        self.retryDelays = retryDelays
    }

    public init(
        tokens: any AccessTokenProvider,
        transport: any HTTPTransport = GoogleSession.defaultTransport,
        retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
        gmailRequestBudget: GmailRequestBudget = GmailRequestBudget()
    ) {
        self.init(session: GoogleSession(tokens: tokens, transport: transport, gmailRequestBudget: gmailRequestBudget), retryDelays: retryDelays)
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
        let items = Self.listQuery(
            query: query,
            labelIDs: labelIDs,
            includeSpamTrash: includeSpamTrash,
            pageToken: pageToken,
            maxResults: maxResults
        )
        return try decode(await send(.get("messages", items)))
    }

    public func messages(
        ids: [String],
        format: MessageFormat,
        metadataHeaders: [String] = []
    ) async throws -> [String: Result<GmailMessage, GmailError>] {
        let items = Self.formatQuery(format, metadataHeaders: metadataHeaders)
        return try await batchDecode(ids) { .get("messages/\($0)", items) }
    }

    /// Parameters shared by `messages.list` and `threads.list`.
    static func listQuery(
        query: String?,
        labelIDs: [String],
        includeSpamTrash: Bool,
        pageToken: String?,
        maxResults: Int
    ) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        items += labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
        if includeSpamTrash { items.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return items
    }

    /// Parameters shared by `messages.get` and `threads.get`.
    static func formatQuery(_ format: MessageFormat, metadataHeaders: [String]) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata {
            items += metadataHeaders.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        }
        return items
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
    /// local cache. Gmail answers each with the thread as it now stands.
    public func modifyThreads(
        ids: [String],
        addLabelIDs: [String],
        removeLabelIDs: [String]
    ) async throws -> LabelChangeResult {
        let body = try encode(LabelChangeRequest(addLabelIds: addLabelIDs, removeLabelIds: removeLabelIDs))
        return try await changeThreads(ids) { .post("threads/\($0)/modify", body: body) }
    }

    public func trashThreads(ids: [String]) async throws -> LabelChangeResult {
        try await changeThreads(ids) { .post("threads/\($0)/trash") }
    }

    public func untrashThreads(ids: [String]) async throws -> LabelChangeResult {
        try await changeThreads(ids) { .post("threads/\($0)/untrash") }
    }

    /// `batchModify` answers with nothing, so one changed message is read back
    /// in `minimal` format for the history ID the change left it at. A failed
    /// read-back leaves the result unconfirmed; the change itself stands.
    public func batchModifyMessages(
        ids: [String],
        addLabelIDs: [String],
        removeLabelIDs: [String]
    ) async throws -> LabelChangeResult {
        for chunk in ids.chunked(into: Self.batchModifyLimit) {
            let body = try encode(BatchModifyRequest(
                ids: Array(chunk),
                addLabelIds: addLabelIDs,
                removeLabelIds: removeLabelIDs
            ))
            _ = try await send(.post("messages/batchModify", body: body))
        }
        guard let sample = ids.last else { return LabelChangeResult() }
        let items = Self.formatQuery(.minimal, metadataHeaders: [])
        do {
            let answer = try await send(.get("messages/\(sample)", items))
            let stamp: HistoryStamp? = try? decode(answer)
            return LabelChangeResult(confirmedHistoryID: stamp?.historyID)
        } catch {
            return LabelChangeResult()
        }
    }

    /// Sends one change per thread and reads the history ID each answer
    /// carries. An answer that can't be read still counts as applied, since
    /// Gmail returned success for it.
    private func changeThreads(_ ids: [String], endpoint: (String) -> Endpoint) async throws -> LabelChangeResult {
        let unique = ids.uniqued()
        let results = try await batch(unique.map(endpoint))
        var result = LabelChangeResult()
        for (id, outcome) in zip(unique, results) {
            switch outcome {
            case .success(let data):
                let stamp: HistoryStamp? = try? decode(data)
                guard let historyID = stamp?.historyID else { continue }
                result.confirmedHistoryID = max(result.confirmedHistoryID ?? 0, historyID)
            case .failure(let error):
                result.failures[id] = error
            }
        }
        return result
    }

    // MARK: Transport

    func send(_ endpoint: Endpoint) async throws -> Data {
        try await send(endpoint.urlRequest()).data
    }

    func send(_ request: URLRequest, forceRefresh: Bool = false) async throws -> (data: Data, response: HTTPURLResponse) {
        try await session.send(request, forceRefresh: forceRefresh,
                               gmailQuotaUnits: GmailRequestBudget.units(for: request),
                               retryReadFailures: request.httpMethod == "GET")
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
            for chunk in Self.batchChunks(pending, endpoints: endpoints) {
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

    private static func batchChunks(_ pending: [Int], endpoints: [Endpoint]) -> [[Int]] {
        var chunks: [[Int]] = []
        var chunk: [Int] = []
        var units = 0
        for index in pending {
            let cost = endpoints[index].quotaUnits
            if !chunk.isEmpty, chunk.count == batchSize || units + cost > GmailRequestBudget.maximumBatchUnits {
                chunks.append(chunk)
                chunk = []
                units = 0
            }
            chunk.append(index)
            units += cost
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private func sendBatch(_ endpoints: [Endpoint], forceRefresh: Bool = false) async throws -> [Result<Data, GmailError>] {
        let boundary = "tern-\(UUID().uuidString)"
        var request = try Endpoint.batchRequest()
        request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try BatchCodec.encode(endpoints, boundary: boundary)

        let (data, response) = try await session.send(
            request, forceRefresh: forceRefresh,
            gmailQuotaUnits: endpoints.reduce(0) { $0 + $1.quotaUnits },
            retryReadFailures: endpoints.allSatisfy { $0.method == "GET" },
            gmailResponseCooldown: Self.batchCooldown
        )
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

    /// Inspect parts while the account's request permit is still held, so a
    /// competing direct request observes the same provider cooldown. A
    /// throttled part cools every lane; a failed part cools only this one.
    private static func batchCooldown(_ data: Data, _ response: HTTPURLResponse) -> GmailRequestBudget.Cooldown? {
        guard let boundary = BatchCodec.boundary(contentType: response.value(forHTTPHeaderField: "Content-Type")),
              let parts = try? BatchCodec.decode(data, boundary: boundary) else { return nil }
        var shared: TimeInterval?
        var lane: TimeInterval?
        for part in parts {
            let error = GmailError(status: part.status, body: part.body)
            switch GmailRequestBudget.cooldown(for: error, retryAfter: part.retryAfter, attempt: 0) {
            case .shared(let seconds)?: shared = max(shared ?? 0, seconds)
            case .lane(let seconds)?: lane = max(lane ?? 0, seconds)
            case nil: break
            }
        }
        if let shared { return .shared(shared) }
        return lane.map { .lane($0) }
    }

    func batchDecode<T: Decodable & Sendable>(
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

    func decode<T: Decodable>(_ data: Data) throws -> T {
        try session.decode(data)
    }

    func encode(_ value: some Encodable) throws -> Data {
        try session.encode(value)
    }
}

/// What Gmail reported for a batch of label changes.
public struct LabelChangeResult: Sendable, Equatable {
    /// The threads or messages Gmail refused, by ID.
    public var failures: [String: GmailError]
    /// The history ID the changed mail stood at afterwards, the highest Gmail
    /// reported. Nil when it reported none.
    public var confirmedHistoryID: Int64?

    public init(failures: [String: GmailError] = [:], confirmedHistoryID: Int64? = nil) {
        self.failures = failures
        self.confirmedHistoryID = confirmedHistoryID
    }
}

/// The one field a change's answer is read for.
private struct HistoryStamp: Decodable {
    let historyId: String?
    var historyID: Int64? { historyId.flatMap(Int64.init) }
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

    var quotaUnits: Int {
        GmailRequestBudget.units(method: method, path: path, format: query.first { $0.name == "format" }?.value)
    }

    static func get(_ path: String, _ query: [URLQueryItem] = []) -> Endpoint {
        Endpoint(method: "GET", path: path, query: query, body: nil)
    }

    static func post(_ path: String, body: Data? = nil) -> Endpoint {
        Endpoint(method: "POST", path: path, query: [], body: body)
    }

    static func patch(_ path: String, body: Data) -> Endpoint {
        Endpoint(method: "PATCH", path: path, query: [], body: body)
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
