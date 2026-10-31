import Foundation

public enum GmailError: Error, Sendable, Equatable {
    /// The access token was rejected even after a forced refresh.
    case unauthorized
    case notFound
    case rateLimited
    case server(status: Int)
    /// `reason` is the most specific one Google gives: the `google.rpc.ErrorInfo`
    /// reason in `details[]`, such as `EXPIRED_SYNC_TOKEN`, or else the first
    /// `errors[]` reason, such as `insufficientPermissions`.
    case http(status: Int, reason: String?)
    /// A `/batch` response had no part for one of its requests.
    case missingBatchPart
    case decoding(String)
    case transport(URLError.Code)
    case invalidRequest(String)
    /// A resumable upload session ended before Gmail stored the message.
    /// Uploading again starts a new session.
    case uploadSessionLost

    /// Whether the same request may succeed later without any change.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .transport, .missingBatchPart, .uploadSessionLost:
            true
        case .unauthorized, .notFound, .http, .decoding, .invalidRequest:
            false
        }
    }

    /// Google refuses a call the token's scopes don't cover with a 403, giving
    /// one of these reasons.
    public var isMissingScope: Bool {
        guard case .http(status: 403, reason: let reason?) = self else { return false }
        return Self.missingScopeReasons.contains(reason)
    }

    static let missingScopeReasons: Set<String> = ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]

    /// The 403 reasons Gmail gives in `errors[]` for a usage limit, which a
    /// later retry can pass.
    static let usageLimitReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "RATE_LIMIT_EXCEEDED"]

    init(status: Int, body: Data) {
        let error = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error
        let listed = error?.errors?.first?.reason
        let reason = error?.errorInfoReason ?? listed
        switch status {
        case 401:
            self = .unauthorized
        case 404:
            self = .notFound
        case 429:
            self = .rateLimited
        case 403 where reason.map(Self.usageLimitReasons.contains) == true:
            self = .rateLimited
        case 500...599:
            self = .server(status: status)
        default:
            self = .http(status: status, reason: reason)
        }
    }
}

/// Google's JSON error body. `errors[]` is the older form. In `details[]`, the
/// `google.rpc.ErrorInfo` entry holds the reason Google's error model calls
/// machine-readable:
/// `{"error": {"code": 403, "errors": [{"reason": "insufficientPermissions"}],
/// "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}`.
private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        struct Item: Decodable {
            let reason: String?
        }

        /// Other detail types carry other fields, so a field that doesn't
        /// decode is left out rather than failing the whole body.
        struct Detail: Decodable {
            let type: String?
            let reason: String?

            enum CodingKeys: String, CodingKey {
                case type = "@type"
                case reason
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try? container.decodeIfPresent(String.self, forKey: .type)
                reason = try? container.decodeIfPresent(String.self, forKey: .reason)
            }
        }

        let errors: [Item]?
        let details: [Detail]?

        enum CodingKeys: String, CodingKey {
            case errors, details
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            errors = try? container.decodeIfPresent([Item].self, forKey: .errors)
            details = try? container.decodeIfPresent([Detail].self, forKey: .details)
        }

        var errorInfoReason: String? {
            details?.first { $0.type == "type.googleapis.com/google.rpc.ErrorInfo" }?.reason
        }
    }

    let error: Body
}
