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

    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = GoogleSession.defaultTransport) {
        self.tokens = tokens
        self.transport = transport
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
