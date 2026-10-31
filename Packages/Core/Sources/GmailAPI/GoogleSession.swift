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

/// What every Google API client here shares: the bearer token, the single
/// retry with a refreshed token after a 401, the transport and JSON coding.
public struct GoogleSession: Sendable {
    /// Ephemeral and without a URL cache. Search terms travel in GET URLs and
    /// responses carry message content, so neither may reach a cache on disk.
    public static let defaultTransport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private let tokens: any AccessTokenProvider
    private let transport: any HTTPTransport
    let gmailRequestBudget: GmailRequestBudget

    public init(
        tokens: any AccessTokenProvider, transport: any HTTPTransport = GoogleSession.defaultTransport,
        gmailRequestBudget: GmailRequestBudget = GmailRequestBudget()
    ) {
        self.tokens = tokens
        self.transport = transport
        self.gmailRequestBudget = gmailRequestBudget
    }

    /// Refreshes once after a 401. Gmail reads also retry transient failures
    /// within their account's shared quota and provider cooldown.
    func send(
        _ request: URLRequest, forceRefresh initiallyForced: Bool = false,
        gmailQuotaUnits: Int? = nil, retryReadFailures: Bool = false,
        gmailResponseCooldown: (@Sendable (Data, HTTPURLResponse) -> TimeInterval?)? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var forceRefresh = initiallyForced
        var hasRefreshed = initiallyForced
        var retries = 0
        while true {
            let refresh = forceRefresh
            forceRefresh = false
            let responseValue: (Data, HTTPURLResponse)
            do {
                if let gmailQuotaUnits {
                    let backoff = pow(2, Double(retries))
                    responseValue = try await gmailRequestBudget.perform(units: gmailQuotaUnits) {
                        let result = try await authorized(request, forceRefresh: refresh)
                        let error = GmailError(status: result.1.statusCode, body: result.0)
                        if error.isRetryable {
                            let delay = GmailRequestBudget.retryAfter(result.1.value(forHTTPHeaderField: "Retry-After")) ?? backoff
                            await gmailRequestBudget.postpone(for: max(1, delay))
                        }
                        if let delay = gmailResponseCooldown?(result.0, result.1) {
                            await gmailRequestBudget.postpone(for: delay)
                        }
                        return result
                    }
                } else {
                    responseValue = try await authorized(request, forceRefresh: refresh)
                }
            } catch let error as GmailError {
                if gmailQuotaUnits != nil, retryReadFailures, error.isRetryable, retries < 3 {
                    await gmailRequestBudget.postpone(for: pow(2, Double(retries)))
                    retries += 1
                    continue
                }
                throw error
            }
            let (data, response) = responseValue
            if (200..<300).contains(response.statusCode) {
                return (data, response)
            }
            if response.statusCode == 401, !hasRefreshed {
                hasRefreshed = true
                forceRefresh = true
                continue
            }
            let error = GmailError(status: response.statusCode, body: data)
            if gmailQuotaUnits != nil, retryReadFailures, error.isRetryable, retries < 3 {
                retries += 1
                continue
            }
            throw error
        }
    }

    private func authorized(_ request: URLRequest, forceRefresh: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let token = try await tokens.accessToken(forceRefresh: forceRefresh)
        try Task.checkCancellation()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled { throw CancellationError() }
            throw GmailError.transport(error.code)
        }
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
