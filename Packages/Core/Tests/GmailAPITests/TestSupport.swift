import Foundation
@testable import GmailAPI

/// Replays canned responses in order and records every request.
actor RecordingTransport: HTTPTransport {
    struct Response {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: String
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty, let url = request.url else { throw URLError(.badServerResponse) }
        let next = responses.removeFirst()
        guard let response = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers) else {
            throw URLError(.badServerResponse)
        }
        return (Data(next.body.utf8), response)
    }
}

/// Returns "token-N", where N counts forced refreshes so far.
actor CountingTokens: AccessTokenProvider {
    private(set) var refreshes = 0

    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { refreshes += 1 }
        return "token-\(refreshes)"
    }
}

extension URLRequest {
    /// The request body as a JSON object, for checking which fields went out.
    func jsonBody() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: httpBody ?? Data())
        guard let dictionary = object as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return dictionary
    }

    /// Path and query exactly as sent, escapes included.
    var percentEncodedTarget: String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
}
