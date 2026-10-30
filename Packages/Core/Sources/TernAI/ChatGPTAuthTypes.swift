import CryptoKit
import Foundation
import Security

public enum ChatGPTAuthError: Error, LocalizedError, Sendable, Equatable {
    case invalidInput, invalidCallback, accessDenied, expiredAttempt, invalidRegistration
    case invalidResponse, invalidIdentity, changedIdentity, expiredToken, missingRefreshToken
    case refreshTooEarly, invalidGrant, rateLimited, unavailable, transportFailed, responseTooLarge, renewalUncertain

    public var errorDescription: String? {
        switch self {
        case .invalidInput, .invalidCallback: "The ChatGPT sign-in response could not be verified. Please try again."
        case .accessDenied: "ChatGPT sign-in was cancelled or permission was declined."
        case .expiredAttempt: "ChatGPT sign-in expired. Please start again."
        case .invalidRegistration: "ChatGPT did not return a valid app registration. Please sign in again."
        case .invalidResponse: "ChatGPT returned an unexpected connection response. Please sign in again."
        case .invalidIdentity: "The ChatGPT account could not be verified. Please sign in again."
        case .changedIdentity: "This sign-in belongs to a different ChatGPT account. Add it as a new connection."
        case .expiredToken, .invalidGrant, .missingRefreshToken: "Your ChatGPT connection has expired. Please sign in again."
        case .refreshTooEarly: "ChatGPT cannot renew this connection yet. Please try again shortly."
        case .rateLimited: "ChatGPT is limiting connection requests. Please try again shortly."
        case .unavailable: "ChatGPT is temporarily unavailable. Please try again."
        case .transportFailed: "Tern could not reach ChatGPT. Check your connection and try again."
        case .responseTooLarge: "ChatGPT returned a connection response that was too large to process."
        case .renewalUncertain: "Tern could not confirm whether ChatGPT renewed this connection. Please sign in again."
        }
    }
}

/// Persist this mapping even when tokens are cleared. A host ID belongs to an installation.
public struct ChatGPTRegistration: Codable, Equatable, Sendable, Identifiable {
    public var id: String { clientID }
    public let clientID: String
    public let hostID: String
    public var subject: String?
    public var email: String?

    public init(clientID: String, hostID: String, subject: String? = nil, email: String? = nil) {
        self.clientID = clientID; self.hostID = hostID; self.subject = subject; self.email = email
    }

    public static func newHostID() -> String { "urn:uuid:" + UUID().uuidString.lowercased() }
}

public struct ChatGPTAccountIdentity: Codable, Equatable, Sendable {
    public let subject: String
    public let email: String?
    public let name: String?
    public init(subject: String, email: String?, name: String?) {
        self.subject = subject; self.email = email; self.name = name
    }
}

/// The native listener must also validate HTTP method, Host, and Origin before passing a URL here.
public struct ChatGPTAuthorizationAttempt: Sendable {
    public let hostID: String
    public let redirectURI: URL
    public let registration: ChatGPTRegistration?
    public let state: String
    public let nonce: String
    public let verifier: String
    public let createdAt: Date
    public let requestConsent: Bool

    public init(hostID: String, redirectURI: URL, registration: ChatGPTRegistration? = nil,
                now: Date = .now, requestConsent: Bool = false) throws {
        guard Self.validHost(hostID), Self.validRedirect(redirectURI),
              registration.map({ validIdentifier($0.clientID) && $0.clientID != "dynamic_agent_client"
                  && $0.hostID == hostID }) ?? true else { throw ChatGPTAuthError.invalidInput }
        self.hostID = hostID; self.redirectURI = redirectURI; self.registration = registration
        self.state = try randomString(); self.nonce = try randomString(); self.verifier = try randomString()
        self.createdAt = now
        self.requestConsent = requestConsent
    }

    public var authorizationURL: URL {
        get throws {
            var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")
            var items = [
                URLQueryItem(name: "client_id", value: registration?.clientID ?? "dynamic_agent_client"),
                URLQueryItem(name: "ext_agent_host_id", value: hostID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
                URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
                URLQueryItem(name: "state", value: state), URLQueryItem(name: "nonce", value: nonce),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            ]
            if registration == nil { items.append(URLQueryItem(name: "agent_name_hint", value: "Tern")) }
            if let email = registration?.email { items.append(URLQueryItem(name: "login_hint", value: email)) }
            if requestConsent { items.append(URLQueryItem(name: "prompt", value: "consent")) }
            url?.queryItems = items
            guard let result = url?.url else { throw ChatGPTAuthError.invalidInput }
            return result
        }
    }

    /// This is a pure check. The caller consumes a successful callback exactly once.
    public func validateCallback(_ url: URL, now: Date = .now) throws -> ChatGPTAuthorizationCode {
        guard now >= createdAt, now.timeIntervalSince(createdAt) <= 600 else { throw ChatGPTAuthError.expiredAttempt }
        guard let callback = URLComponents(url: url, resolvingAgainstBaseURL: false),
              callback.scheme == redirectURI.scheme, callback.host == "127.0.0.1",
              callback.port == redirectURI.port, callback.path == redirectURI.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil else {
            throw ChatGPTAuthError.invalidCallback
        }
        let items = callback.queryItems ?? []
        let sensitive = ["code", "state", "client_id", "error", "scope", "error_description"]
        guard sensitive.allSatisfy({ key in items.filter { $0.name == key }.count <= 1 }),
              let returnedState = items.first(where: { $0.name == "state" })?.value,
              constantTimeEqual(returnedState, state) else { throw ChatGPTAuthError.invalidCallback }
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? ChatGPTAuthError.accessDenied : ChatGPTAuthError.invalidCallback
        }
        let returnedID = items.first(where: { $0.name == "client_id" })?.value
        let clientID = returnedID ?? registration?.clientID
        guard let clientID, validIdentifier(clientID), clientID != "dynamic_agent_client",
              registration.map({ returnedID == nil || returnedID == $0.clientID }) ?? true else {
            throw ChatGPTAuthError.invalidRegistration
        }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              validToken(code) else { throw ChatGPTAuthError.invalidCallback }
        return ChatGPTAuthorizationCode(
            registration: ChatGPTRegistration(clientID: clientID, hostID: hostID,
                subject: registration?.subject, email: registration?.email), code: code)
    }

    private static func validHost(_ value: String) -> Bool {
        value.hasPrefix("urn:uuid:") && UUID(uuidString: String(value.dropFirst(9))) != nil
    }
    private static func validRedirect(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == "127.0.0.1" && (url.port ?? 0) > 0
            && (url.port ?? 0) <= 65535 && url.path == "/auth/callback"
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
}

public struct ChatGPTAuthorizationCode: Sendable {
    public let registration: ChatGPTRegistration
    public let code: String
}

/// Store in Keychain before identity verification to preserve refresh-token rotation across interruption.
public struct ChatGPTPendingTokens: Codable, Sendable {
    public let registration: ChatGPTRegistration
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let scopes: [String]
    public let receivedAt: Date
    public let expiresAt: Date
    public let earliestRefreshAt: Date?
    public let expectedNonce: String?
    public let previousIdentity: ChatGPTAccountIdentity?
    public let previousIDToken: String?
}

public struct ChatGPTCredentials: Codable, Sendable {
    public let registration: ChatGPTRegistration
    public let account: ChatGPTAccountIdentity
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String
    public let scopes: [String]
    public let receivedAt: Date
    public let expiresAt: Date
    public let earliestRefreshAt: Date?

    public var canUsePlan: Bool {
        scopes.contains("resource.invoke") && scopes.contains("chatgpt.tokens.use.direct")
    }
    public func needsRefresh(at now: Date = .now) -> Bool { expiresAt.timeIntervalSince(now) <= 60 }
}

func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
        !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
    }
}
func validToken(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 16_384 && value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
}
func randomString() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw ChatGPTAuthError.unavailable
    }
    return Data(bytes).base64URL
}
func constantTimeEqual(_ first: String, _ second: String) -> Bool {
    let a = Array(first.utf8), b = Array(second.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(strictBase64URL value: String) {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }), value.count % 4 != 1 else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), decoded.base64URL == value else { return nil }
        self = decoded
    }
}
