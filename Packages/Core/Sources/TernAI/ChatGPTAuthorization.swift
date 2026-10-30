import Foundation

public typealias ChatGPTAuthTransport = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

/// OAuth transport for Tern's own public-client registration. It never reads Codex credentials.
public struct ChatGPTAuthorization: Sendable {
    private static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    private let transport: ChatGPTAuthTransport
    private let now: @Sendable () -> Date

    public init(transport: ChatGPTAuthTransport? = nil, now: @escaping @Sendable () -> Date = { .now }) {
        self.transport = transport ?? Self.networkTransport
        self.now = now
    }

    /// Save code.registration before calling this; the one-time code is not retried here.
    public func exchange(code: ChatGPTAuthorizationCode, attempt: ChatGPTAuthorizationAttempt) async throws -> ChatGPTPendingTokens {
        guard now().timeIntervalSince(attempt.createdAt) <= 600,
              code.registration.hostID == attempt.hostID,
              attempt.registration.map({ $0.clientID == code.registration.clientID }) ?? true,
              validToken(code.code) else { throw ChatGPTAuthError.expiredAttempt }
        try await discover()
        return try await tokens(form: [
            "grant_type": "authorization_code", "client_id": code.registration.clientID,
            "code": code.code, "code_verifier": attempt.verifier,
            "redirect_uri": attempt.redirectURI.absoluteString, "resource": Self.resource,
        ], registration: code.registration, nonce: attempt.nonce, previous: nil)
    }

    /// The caller serializes this operation per registration and checkpoints its result before verify.
    public func refresh(credentials: ChatGPTCredentials) async throws -> ChatGPTPendingTokens {
        guard validIdentifier(credentials.registration.clientID), credentials.registration.clientID != "dynamic_agent_client",
              credentials.registration.subject == credentials.account.subject else { throw ChatGPTAuthError.invalidIdentity }
        guard let refresh = credentials.refreshToken, validToken(refresh) else { throw ChatGPTAuthError.missingRefreshToken }
        if let earliest = credentials.earliestRefreshAt, now() < earliest { throw ChatGPTAuthError.refreshTooEarly }
        try await discover()
        try Task.checkCancellation()
        do {
            return try await tokens(form: [
                "grant_type": "refresh_token", "client_id": credentials.registration.clientID,
                "refresh_token": refresh, "resource": Self.resource,
            ], registration: credentials.registration, nonce: nil, previous: credentials)
        } catch ChatGPTAuthError.invalidGrant { throw ChatGPTAuthError.invalidGrant }
        catch ChatGPTAuthError.rateLimited { throw ChatGPTAuthError.rateLimited }
        catch ChatGPTAuthError.refreshTooEarly { throw ChatGPTAuthError.refreshTooEarly }
        catch {
            // A dispatched request may already have rotated the token. Do not retry the old token.
            throw ChatGPTAuthError.renewalUncertain
        }
    }

    public func verify(_ pending: ChatGPTPendingTokens) async throws -> ChatGPTCredentials {
        try Task.checkCancellation()
        guard pending.expiresAt > now() else { throw ChatGPTAuthError.expiredToken }
        guard validIdentifier(pending.registration.clientID), pending.registration.clientID != "dynamic_agent_client",
              validToken(pending.accessToken), pending.scopes.contains("openid"),
              pending.receivedAt <= now().addingTimeInterval(60),
              pending.expiresAt > pending.receivedAt,
              pending.expiresAt.timeIntervalSince(pending.receivedAt) <= 3600 else { throw ChatGPTAuthError.invalidResponse }
        let identity: ChatGPTAccountIdentity
        let retainedIDToken: String
        if let token = pending.idToken {
            let jwks = try await request(path: "/.well-known/jwks.json")
            identity = try ChatGPTIdentityVerifier.verify(idToken: token, jwks: jwks,
                clientID: pending.registration.clientID, nonce: pending.expectedNonce,
                expectedSubject: pending.registration.subject, now: pending.receivedAt)
            retainedIDToken = token
        } else if pending.expectedNonce == nil, let previous = pending.previousIdentity,
                  let oldToken = pending.previousIDToken, validToken(oldToken),
                  previous.subject == pending.registration.subject {
            identity = previous
            retainedIDToken = oldToken
        } else { throw ChatGPTAuthError.invalidIdentity }
        try Task.checkCancellation()
        guard pending.expiresAt > now() else { throw ChatGPTAuthError.expiredToken }
        var registration = pending.registration
        registration.subject = identity.subject; registration.email = identity.email
        return ChatGPTCredentials(registration: registration, account: identity,
            accessToken: pending.accessToken, refreshToken: pending.refreshToken, idToken: retainedIDToken,
            scopes: pending.scopes, receivedAt: pending.receivedAt, expiresAt: pending.expiresAt,
            earliestRefreshAt: pending.earliestRefreshAt)
    }

    public func revoke(credentials: ChatGPTCredentials) async throws {
        guard let refreshToken = credentials.refreshToken else { return }
        try await revoke(registration: credentials.registration, refreshToken: refreshToken)
    }

    /// Also accepts a checkpointed replacement token when identity verification was interrupted.
    public func revoke(registration: ChatGPTRegistration, refreshToken: String) async throws {
        guard validIdentifier(registration.clientID), registration.clientID != "dynamic_agent_client",
              validToken(refreshToken) else { throw ChatGPTAuthError.invalidInput }
        try await discover()
        _ = try await request(path: "/api/accounts/oauth/revoke", form: [
            "token": refreshToken, "token_type_hint": "refresh_token", "client_id": registration.clientID,
        ], requiresJSON: false)
    }

    private func discover() async throws {
        let data = try await request(path: "/.well-known/openid-configuration", limit: 32_768)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["issuer"] as? String == Self.issuer,
              object["authorization_endpoint"] as? String == Self.issuer + "/api/accounts/authorize",
              object["token_endpoint"] as? String == Self.issuer + "/api/accounts/oauth/token",
              object["revocation_endpoint"] as? String == Self.issuer + "/api/accounts/oauth/revoke",
              object["jwks_uri"] as? String == Self.issuer + "/.well-known/jwks.json",
              (object["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
              (object["id_token_signing_alg_values_supported"] as? [String])?.contains("RS256") == true else {
            throw ChatGPTAuthError.invalidResponse
        }
    }

    private func tokens(form: [String: String], registration: ChatGPTRegistration, nonce: String?,
                        previous: ChatGPTCredentials?) async throws -> ChatGPTPendingTokens {
        guard validIdentifier(registration.clientID), registration.clientID != "dynamic_agent_client" else {
            throw ChatGPTAuthError.invalidRegistration
        }
        let data = try await request(path: "/api/accounts/oauth/token", form: form)
        let received = now()
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
              response.tokenType == "Bearer", validToken(response.accessToken),
              response.refreshToken.map(validToken) ?? true,
              response.idToken.map(validToken) ?? true,
              response.expiresIn.isFinite, response.expiresIn > 0, response.expiresIn <= 3600,
              response.expiresIn.rounded(.towardZero) == response.expiresIn else { throw ChatGPTAuthError.invalidResponse }
        let scopes: [String]
        if let scope = response.scope {
            scopes = scope.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard !scopes.isEmpty, scopes.count <= 32, Set(scopes).count == scopes.count,
                  scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && $0.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e } }) else {
                throw ChatGPTAuthError.invalidResponse
            }
        } else if let previous { scopes = previous.scopes }
        else { throw ChatGPTAuthError.invalidResponse }
        guard scopes.contains("openid"), !scopes.contains("offline_access") || response.refreshToken != nil,
              previous != nil || response.idToken != nil else { throw ChatGPTAuthError.invalidResponse }
        if let previous {
            guard Set(scopes).isSubset(of: Set(previous.scopes)), let replacement = response.refreshToken,
                  replacement != previous.refreshToken else { throw ChatGPTAuthError.invalidResponse }
        }
        return ChatGPTPendingTokens(registration: registration, accessToken: response.accessToken,
            refreshToken: response.refreshToken, idToken: response.idToken, scopes: scopes,
            receivedAt: received, expiresAt: received.addingTimeInterval(response.expiresIn),
            earliestRefreshAt: response.earliestRefreshAt?.date, expectedNonce: nonce,
            previousIdentity: previous?.account, previousIDToken: previous?.idToken)
    }

    private func request(path: String, form: [String: String]? = nil, limit: Int = 65_536,
                         requiresJSON: Bool = true) async throws -> Data {
        try Task.checkCancellation()
        guard let url = URL(string: Self.issuer + path) else { throw ChatGPTAuthError.invalidInput }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let pairs = try form.sorted(by: { $0.key < $1.key }).map { key, value -> String in
                guard let key = key.addingPercentEncoding(withAllowedCharacters: allowed),
                      let value = value.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ChatGPTAuthError.invalidInput }
                return key + "=" + value
            }
            request.httpBody = Data(pairs.joined(separator: "&").utf8)
            guard (request.httpBody?.count ?? 0) <= 32_768 else { throw ChatGPTAuthError.invalidInput }
        }
        do {
            let (data, response) = try await transport(request, limit)
            try Task.checkCancellation()
            guard response.url == url, data.count <= limit else { throw ChatGPTAuthError.responseTooLarge }
            guard response.statusCode == 200 else {
                if response.statusCode == 429 { throw ChatGPTAuthError.rateLimited }
                if response.statusCode >= 500 { throw ChatGPTAuthError.unavailable }
                let error = (try? JSONDecoder().decode(OAuthFailure.self, from: data))?.error
                if let error, ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                               "refresh_token_invalidated", "refresh_token_reused"].contains(error) { throw ChatGPTAuthError.invalidGrant }
                if error == "invalid_client" { throw ChatGPTAuthError.invalidRegistration }
                if error == "refresh_token_too_early" || error == "refresh_too_early" { throw ChatGPTAuthError.refreshTooEarly }
                throw ChatGPTAuthError.invalidResponse
            }
            if requiresJSON {
                guard response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
                    .trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw ChatGPTAuthError.invalidResponse }
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatGPTAuthError { throw error }
        catch { throw Task.isCancelled ? CancellationError() : ChatGPTAuthError.transportFailed }
    }

    private static func networkTransport(_ request: URLRequest, _ limit: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChatGPTAuthError.invalidResponse }
        guard response.expectedContentLength <= Int64(limit) else { throw ChatGPTAuthError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ChatGPTAuthError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private struct OAuthFailure: Decodable { let error: String }
    private struct TokenResponse: Decodable {
        let accessToken: String; let refreshToken: String?; let idToken: String?
        let tokenType: String; let expiresIn: Double; let scope: String?; let earliestRefreshAt: RefreshTime?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
            case tokenType = "token_type", expiresIn = "expires_in", scope, earliestRefreshAt = "earliest_refresh_at"
        }
    }
    private struct RefreshTime: Decodable {
        let date: Date
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self), seconds.isFinite, seconds > 0 {
                date = Date(timeIntervalSince1970: seconds)
            } else {
                let string = try container.decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let parsed = formatter.date(from: string) { date = parsed; return }
                formatter.formatOptions = [.withInternetDateTime]
                guard let parsed = formatter.date(from: string) else { throw ChatGPTAuthError.invalidResponse }
                date = parsed
            }
        }
    }
}
