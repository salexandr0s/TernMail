import Foundation

public enum GmailError: Error, Sendable, Equatable {
    /// The access token was rejected even after a forced refresh.
    case unauthorized
    case notFound
    case rateLimited
    case server(status: Int)
    case http(status: Int, reason: String?)
    /// A `/batch` response had no part for one of its requests.
    case missingBatchPart
    case decoding(String)
    case transport(URLError.Code)
    case invalidRequest(String)

    /// Whether the same request may succeed later without any change.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .transport, .missingBatchPart:
            true
        case .unauthorized, .notFound, .http, .decoding, .invalidRequest:
            false
        }
    }

    init(status: Int, body: Data) {
        let reason = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error.errors?.first?.reason
        switch status {
        case 401:
            self = .unauthorized
        case 404:
            self = .notFound
        case 429:
            self = .rateLimited
        case 403 where reason == "rateLimitExceeded" || reason == "userRateLimitExceeded":
            self = .rateLimited
        case 500...599:
            self = .server(status: status)
        default:
            self = .http(status: status, reason: reason)
        }
    }
}

/// Google's JSON error body: `{"error": {"code": 403, "errors": [{"reason": "..."}]}}`.
private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        struct Item: Decodable {
            let reason: String?
        }

        let errors: [Item]?
    }

    let error: Body
}
