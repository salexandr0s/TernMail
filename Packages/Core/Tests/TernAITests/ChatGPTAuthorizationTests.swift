import CryptoKit
import Foundation
import Testing
@testable import TernAI

struct ChatGPTAuthorizationTests {
    @Test func registrationUsesPKCEAndRejectsUnrelatedCallbacks() throws {
        let attempt = try makeAttempt()
        let url = try attempt.authorizationURL
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first(where: { $0.name == "client_id" })?.value == "dynamic_agent_client")
        #expect(items.first(where: { $0.name == "agent_name_hint" })?.value == "Tern")
        #expect(items.first(where: { $0.name == "ext_agent_host_id" })?.value == attempt.hostID)
        #expect(items.first(where: { $0.name == "code_challenge" })?.value == Data(SHA256.hash(data: Data(attempt.verifier.utf8))).base64URL)
        let success = try callback(attempt, extra: [])
        #expect(try attempt.validateCallback(success, now: AuthTestSigner.now).registration.clientID == "oaiapp_tern")
        for invalid in [
            try callback(attempt, extra: [URLQueryItem(name: "state", value: "extra")]),
            try callback(attempt, extra: [URLQueryItem(name: "code", value: "extra")]),
            try callback(attempt, extra: [URLQueryItem(name: "client_id", value: "extra")]),
            try #require(URL(string: success.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))),
        ] {
            #expect(throws: (any Error).self) { try attempt.validateCallback(invalid, now: AuthTestSigner.now) }
        }
        #expect(throws: ChatGPTAuthError.expiredAttempt) {
            try attempt.validateCallback(success, now: AuthTestSigner.now.addingTimeInterval(601))
        }
        // A rejected callback does not consume the pending attempt.
        #expect(try attempt.validateCallback(success, now: AuthTestSigner.now).code == "authorization-code")
    }

    @Test func returningRegistrationCannotBeReplacedByCallback() throws {
        let hostID = ChatGPTRegistration.newHostID()
        let registration = ChatGPTRegistration(clientID: "oaiapp_tern", hostID: hostID, subject: "account-subject")
        let attempt = try ChatGPTAuthorizationAttempt(hostID: hostID,
            redirectURI: #require(URL(string: "http://127.0.0.1:54543/auth/callback")), registration: registration, now: AuthTestSigner.now)
        let items = try #require(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(!items.contains(where: { $0.name == "agent_name_hint" }))
        #expect(items.first(where: { $0.name == "client_id" })?.value == registration.clientID)
        #expect(!items.contains(where: { $0.name == "prompt" }))
        let consent = try ChatGPTAuthorizationAttempt(hostID: hostID, redirectURI: attempt.redirectURI,
            registration: registration, now: AuthTestSigner.now, requestConsent: true)
        let consentItems = try #require(URLComponents(url: consent.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(consentItems.first(where: { $0.name == "prompt" })?.value == "consent")
        #expect(consentItems.first(where: { $0.name == "scope" })?.value?.contains("chatgpt.tokens.use.direct") == true)
        #expect(consentItems.first(where: { $0.name == "client_id" })?.value == registration.clientID)
        var components = try #require(URLComponents(url: attempt.redirectURI, resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "state", value: attempt.state), URLQueryItem(name: "code", value: "code")]
        #expect(try attempt.validateCallback(#require(components.url), now: AuthTestSigner.now).registration == registration)
        components.queryItems?.append(URLQueryItem(name: "client_id", value: "other-app"))
        #expect(throws: ChatGPTAuthError.invalidRegistration) {
            try attempt.validateCallback(#require(components.url), now: AuthTestSigner.now)
        }
    }

    @Test func checkpointCanRecoverAfterJWKSFailureAndIdentityOnlyIsNotPlanAccess() async throws {
        let signer = try AuthTestSigner()
        let attempt = try makeAttempt()
        let token = try signer.token(overrides: ["nonce": attempt.nonce, "exp": AuthTestSigner.now.timeIntervalSince1970 + 30])
        let endpoint = AuthEndpointFixture(token: try tokenResponse(idToken: token, scope: "openid profile email"), jwks: signer.jwks)
        let auth = ChatGPTAuthorization(transport: { request, limit in try await endpoint.respond(request, limit: limit) }, now: { AuthTestSigner.now })
        let code = try attempt.validateCallback(callback(attempt, extra: []), now: AuthTestSigner.now)
        let pending = try await auth.exchange(code: code, attempt: attempt)
        #expect(pending.registration.clientID == code.registration.clientID)
        #expect(pending.receivedAt == AuthTestSigner.now)
        await endpoint.failJWKS()
        await #expect(throws: ChatGPTAuthError.transportFailed) { try await auth.verify(pending) }
        let restored = try JSONDecoder().decode(ChatGPTPendingTokens.self, from: JSONEncoder().encode(pending))
        let recovery = ChatGPTAuthorization(transport: { request, limit in try await endpoint.respond(request, limit: limit) },
            now: { AuthTestSigner.now.addingTimeInterval(120) })
        let credentials = try await recovery.verify(restored)
        #expect(credentials.account.subject == "account-subject")
        #expect(!credentials.canUsePlan)
        #expect(credentials.refreshToken == nil)
        let requests = await endpoint.requests
        let exchange = try #require(requests.first(where: { $0.url?.path == "/api/accounts/oauth/token" }))
        let body = try #require(exchange.httpBody).utf8String
        #expect(body.contains("client_id=oaiapp_tern"))
        #expect(body.contains("code_verifier=" + attempt.verifier))
        #expect(!body.contains("client_secret"))
    }

    @Test func refreshRotatesWithoutExtendingOriginalReceiptAndRevokesReplacement() async throws {
        let signer = try AuthTestSigner()
        let credentials = try sampleCredentials(idToken: signer.token())
        let endpoint = AuthEndpointFixture(token: try tokenResponse(idToken: nil, refresh: "replacement-refresh", scope: nil), jwks: signer.jwks)
        let auth = ChatGPTAuthorization(transport: { request, limit in try await endpoint.respond(request, limit: limit) }, now: { AuthTestSigner.now })
        let pending = try await auth.refresh(credentials: credentials)
        let restored = try JSONDecoder().decode(ChatGPTPendingTokens.self, from: JSONEncoder().encode(pending))
        let refreshed = try await auth.verify(restored)
        #expect(refreshed.refreshToken == "replacement-refresh")
        #expect(refreshed.idToken == credentials.idToken)
        #expect(refreshed.scopes == credentials.scopes)
        #expect(refreshed.expiresAt == AuthTestSigner.now.addingTimeInterval(3600))
        try await auth.revoke(registration: pending.registration, refreshToken: #require(pending.refreshToken))
        let revoke = try #require(await endpoint.requests.last)
        #expect(revoke.httpBody?.utf8String.contains("token=replacement-refresh") == true)
        let late = ChatGPTAuthorization(transport: { request, limit in try await endpoint.respond(request, limit: limit) },
            now: { AuthTestSigner.now.addingTimeInterval(3601) })
        await #expect(throws: ChatGPTAuthError.expiredToken) { try await late.verify(restored) }
    }

    @Test func refusesRefreshBeforeEarliestTime() async throws {
        let credentials = sampleCredentials(idToken: "stored-id-token", earliest: AuthTestSigner.now.addingTimeInterval(30))
        let auth = ChatGPTAuthorization(transport: { _, _ in Issue.record("Refresh must not be sent early"); throw ChatGPTAuthError.transportFailed }, now: { AuthTestSigner.now })
        await #expect(throws: ChatGPTAuthError.refreshTooEarly) { try await auth.refresh(credentials: credentials) }
    }

    @Test func ambiguousRefreshRequiresReauthorizationInsteadOfRetry() async throws {
        let credentials = sampleCredentials(idToken: "stored-id-token")
        let endpoint = AuthEndpointFixture(token: Data(), jwks: Data())
        await endpoint.failTokenRequest()
        let auth = ChatGPTAuthorization(transport: { request, limit in try await endpoint.respond(request, limit: limit) }, now: { AuthTestSigner.now })
        await #expect(throws: ChatGPTAuthError.renewalUncertain) { try await auth.refresh(credentials: credentials) }
        #expect(await endpoint.requests.filter { $0.url?.path == "/api/accounts/oauth/token" }.count == 1)
    }

    private func makeAttempt() throws -> ChatGPTAuthorizationAttempt {
        try ChatGPTAuthorizationAttempt(hostID: ChatGPTRegistration.newHostID(),
            redirectURI: #require(URL(string: "http://127.0.0.1:54543/auth/callback")), now: AuthTestSigner.now)
    }
    private func callback(_ attempt: ChatGPTAuthorizationAttempt, extra: [URLQueryItem]) throws -> URL {
        var components = try #require(URLComponents(url: attempt.redirectURI, resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "state", value: attempt.state), URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "client_id", value: "oaiapp_tern")] + extra
        return try #require(components.url)
    }
    private func tokenResponse(idToken: String?, refresh: String? = nil, scope: String?) throws -> Data {
        var object: [String: Any] = ["access_token": "controlled-access", "token_type": "Bearer", "expires_in": 3600]
        object["id_token"] = idToken; object["refresh_token"] = refresh; object["scope"] = scope
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func sampleCredentials(idToken: String, earliest: Date? = nil) -> ChatGPTCredentials {
        ChatGPTCredentials(registration: ChatGPTRegistration(clientID: "oaiapp_tern", hostID: ChatGPTRegistration.newHostID(), subject: "account-subject"),
            account: ChatGPTAccountIdentity(subject: "account-subject", email: "test@example.invalid", name: "Test Account"),
            accessToken: "old-access", refreshToken: "old-refresh", idToken: idToken,
            scopes: ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"],
            receivedAt: AuthTestSigner.now.addingTimeInterval(-3500), expiresAt: AuthTestSigner.now.addingTimeInterval(100), earliestRefreshAt: earliest)
    }
}

private actor AuthEndpointFixture {
    let token: Data
    let jwks: Data
    var requests = [URLRequest]()
    var shouldFailJWKS = false
    var shouldFailToken = false
    init(token: Data, jwks: Data) { self.token = token; self.jwks = jwks }
    func failJWKS() { shouldFailJWKS = true }
    func failTokenRequest() { shouldFailToken = true }
    func respond(_ request: URLRequest, limit: Int) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let data: Data
        switch url.path {
        case "/.well-known/openid-configuration":
            data = Data("""
            {"issuer":"https://auth.openai.com","authorization_endpoint":"https://auth.openai.com/api/accounts/authorize","token_endpoint":"https://auth.openai.com/api/accounts/oauth/token","revocation_endpoint":"https://auth.openai.com/api/accounts/oauth/revoke","jwks_uri":"https://auth.openai.com/.well-known/jwks.json","code_challenge_methods_supported":["S256"],"id_token_signing_alg_values_supported":["RS256"]}
            """.utf8)
        case "/api/accounts/oauth/token":
            if shouldFailToken { throw URLError(.networkConnectionLost) }
            data = token
        case "/.well-known/jwks.json":
            if shouldFailJWKS { shouldFailJWKS = false; throw URLError(.notConnectedToInternet) }
            data = jwks
        case "/api/accounts/oauth/revoke": data = Data()
        default: throw ChatGPTAuthError.invalidInput
        }
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
    }
}

private extension Data { var utf8String: String { String(decoding: self, as: UTF8.self) } }
