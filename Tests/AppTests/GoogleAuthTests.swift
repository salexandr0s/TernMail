import AppAuth
import AppAuthCore
import Foundation
import GmailAPI
import MailStore
import Testing
@testable import Tern

@MainActor
@Suite struct GoogleAuthTests {
    private var configuration: GoogleAuth.Configuration {
        .init(clientID: "synthetic-client", redirectURL: URL(string: "com.example.tern:/oauthredirect")!)
    }

    @Test func replacementGrantsRequestOfflineAccessAndKeepAppAuthProofs() throws {
        let auth = GoogleAuth(configuration: configuration)
        let request = try auth.authorizationRequest(loginHint: "synthetic-subject", features: [.calendar, .contacts])
        let next = try auth.authorizationRequest()
        let initialScopes = Set((next.scope ?? "").split(separator: " ").map(String.init))
        #expect(initialScopes == Set(GoogleScopes.base + [GoogleScopes.contacts, GoogleScopes.otherContacts]))
        #expect(request.additionalParameters?["access_type"] == "offline")
        #expect(request.additionalParameters?["prompt"] == "consent")
        #expect(request.additionalParameters?["login_hint"] == "synthetic-subject")
        #expect(request.redirectURL == configuration.redirectURL)
        #expect(request.responseType == OIDResponseTypeCode)
        #expect(request.codeChallengeMethod == "S256")
        #expect(request.codeVerifier?.isEmpty == false)
        #expect(request.codeChallenge?.isEmpty == false)
        #expect(request.state?.isEmpty == false && request.state != next.state)
        #expect(request.nonce?.isEmpty == false && request.nonce != next.nonce)
        let requestedScopes = Set((request.scope ?? "").split(separator: " ").map(String.init))
        let expectedScopes = Set(GoogleScopes.request(features: [.calendar, .contacts], isWorkspace: false))
        #expect(requestedScopes == expectedScopes)
    }

    @Test func browserFailureFinishesAndAllowsAnotherAttempt() async throws {
        let opened = AsyncStream<URL>.makeStream()
        var attempts = 0
        let auth = GoogleAuth(configuration: configuration, openBrowser: { url in
            attempts += 1
            if attempts == 1 { return false }
            opened.continuation.yield(url)
            return true
        })
        await #expect(throws: GoogleAuth.AuthError.browserUnavailable) { _ = try await auth.signIn() }
        let retry = Task { _ = try await auth.signIn() }
        var iterator = opened.stream.makeAsyncIterator()
        let url = try #require(await iterator.next())
        #expect(url.scheme == "https" && url.host == "accounts.google.com")
        auth.cancelSignIn()
        await #expect(throws: CancellationError.self) { try await retry.value }
        #expect(attempts == 2)
    }

    @Test func staleAndMalformedCallbacksCannotCancelTheCurrentAttempt() async throws {
        let opened = AsyncStream<URL>.makeStream()
        let auth = GoogleAuth(configuration: configuration, openBrowser: { opened.continuation.yield($0); return true })
        var iterator = opened.stream.makeAsyncIterator()
        let first = Task { _ = try await auth.signIn() }
        let oldURL = try #require(await iterator.next())
        let oldState = try state(in: oldURL)
        auth.cancelSignIn()

        let second = Task { _ = try await auth.signIn() }
        let currentURL = try #require(await iterator.next())
        let currentState = try state(in: currentURL)
        first.cancel()
        #expect(oldState != currentState)
        #expect(auth.handleRedirect(try callback(state: oldState)))
        #expect(auth.handleRedirect(try callback(state: nil)))
        #expect(auth.handleRedirect(try callback(state: currentState, duplicateState: true)))
        #expect(auth.handleRedirect(try callback(state: currentState, path: "/wrong-path")))
        #expect(!auth.handleRedirect(URL(string: "mailto:synthetic@example.com")!))
        // If a stale callback reached AppAuth, it would finish this attempt
        // with a state error before our explicit cancellation could finish it.
        auth.cancelSignIn()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(auth.handleRedirect(try callback(state: currentState)))
    }

    @Test func matchingCallbackFinishesThroughAppAuthWithoutExposingProviderText() async throws {
        let opened = AsyncStream<URL>.makeStream()
        let auth = GoogleAuth(configuration: configuration, openBrowser: { opened.continuation.yield($0); return true })
        let signIn = Task { _ = try await auth.signIn() }
        var iterator = opened.stream.makeAsyncIterator()
        let url = try #require(await iterator.next())
        let callback = try callback(state: state(in: url))
        #expect(auth.handleRedirect(callback))
        await #expect(throws: GoogleAuth.AuthError.authorizationFailed) { try await signIn.value }
        #expect(auth.handleRedirect(callback))
    }

    @Test func taskCancellationFinishesTheFlowAndLateCallbacksStayConsumed() async throws {
        let opened = AsyncStream<URL>.makeStream()
        let auth = GoogleAuth(configuration: configuration, openBrowser: { opened.continuation.yield($0); return true })
        let signIn = Task { _ = try await auth.signIn() }
        var iterator = opened.stream.makeAsyncIterator()
        let url = try #require(await iterator.next())
        signIn.cancel()
        await #expect(throws: CancellationError.self) { try await signIn.value }
        #expect(auth.handleRedirect(try callback(state: state(in: url))))
    }

    @Test func abandonedBrowserAttemptTimesOut() async throws {
        let opened = AsyncStream<URL>.makeStream()
        let timeout = AsyncStream<Void>.makeStream()
        let auth = GoogleAuth(configuration: configuration,
            openBrowser: { opened.continuation.yield($0); return true }, sleep: { _ in
                for await _ in timeout.stream { return }
                try Task.checkCancellation()
            })
        let signIn = Task { _ = try await auth.signIn() }
        var iterator = opened.stream.makeAsyncIterator()
        let url = try #require(await iterator.next())
        timeout.continuation.yield(())
        await #expect(throws: GoogleAuth.AuthError.timedOut) { try await signIn.value }
        #expect(auth.handleRedirect(try callback(state: state(in: url))))
    }

    @Test func aNewGrantWithoutRefreshCredentialsCannotReplaceADurableSession() throws {
        let request = try GoogleAuth(configuration: configuration).authorizationRequest()
        let authorization = OIDAuthorizationResponse(request: request, parameters: ["code": "synthetic-code" as NSString])
        let tokenRequest = try #require(authorization.tokenExchangeRequest())
        let claims: [String: Any] = [
            "iss": "https://accounts.google.com", "sub": "synthetic-subject", "aud": configuration.clientID,
            "iat": 1_700_000_000, "exp": 1_700_003_600, "email": "synthetic@example.com",
        ]
        func encoded(_ value: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: value).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let idToken = try encoded(["alg": "RS256"]) + "." + encoded(claims) + ".c3ludGhldGlj"
        var parameters: [String: NSObject & NSCopying] = [
            "access_token": "synthetic-access" as NSString, "token_type": "Bearer" as NSString,
            "id_token": idToken as NSString, "expires_in": 3600 as NSNumber,
        ]
        let shortLived = OIDAuthState(authorizationResponse: authorization,
            tokenResponse: OIDTokenResponse(request: tokenRequest, parameters: parameters))
        #expect(throws: GoogleAuth.AuthError.missingRefreshToken) {
            try GoogleAuth.signedInUser(state: shortLived, accountID: "synthetic-subject", features: [])
        }
        parameters["refresh_token"] = "synthetic-refresh" as NSString
        let durable = OIDAuthState(authorizationResponse: authorization,
            tokenResponse: OIDTokenResponse(request: tokenRequest, parameters: parameters))
        #expect(try GoogleAuth.signedInUser(state: durable, accountID: "synthetic-subject", features: []).id == "synthetic-subject")
        #expect(throws: GoogleAuth.AuthError.otherAccount) {
            try GoogleAuth.signedInUser(state: durable, accountID: "different-subject", features: [])
        }
    }

    @Test func addAccountKeepsAnAddedAccountsSessionUnlessTheGrantKeepsItsFeatures() {
        func account(_ features: Set<AccountFeature>, isWorkspace: Bool) -> AccountRecord {
            AccountRecord(id: "synthetic-subject", email: "synthetic@example.com", displayName: nil,
                grantedScopes: GoogleScopes.request(features: features, isWorkspace: isWorkspace),
                addedAt: Date(timeIntervalSince1970: 1_700_000_000), hostedDomain: isWorkspace ? "example.com" : nil,
                enabledFeatures: AccountFeature.names(of: features))
        }
        // What Add Account asks for, since it doesn't know the account yet.
        let addAccountGrant = GoogleScopes.request(features: GoogleScopes.initialFeatures, isWorkspace: false)
        #expect(AppModel.addAccountReplacesSession(of: account([.contacts], isWorkspace: false), granted: addAccountGrant))
        let calendar = account([.contacts, .calendar], isWorkspace: false)
        #expect(!AppModel.addAccountReplacesSession(of: calendar, granted: addAccountGrant))
        #expect(AppModel.addAccountReplacesSession(of: calendar, granted: calendar.grantedScopes))
        // Contacts is covered without the directory, but the account would stop searching it.
        let workspace = account([.contacts], isWorkspace: true)
        #expect(!AppModel.addAccountReplacesSession(of: workspace, granted: addAccountGrant))
        #expect(AppModel.addAccountReplacesSession(of: workspace, granted: workspace.grantedScopes))
    }

    @Test func aFailedRefreshReusesTheOldTokenOnlyWhileItIsUnexpiredAndNotRejected() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = now.addingTimeInterval(600)
        let timedOut = NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.networkError.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)])
        let unavailable = NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.serverError.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: OIDHTTPErrorDomain, code: 503)])
        #expect(try AccountSession.usableToken("new", error: nil, expiresAt: valid, rejected: "old", now: now) == "new")
        #expect(try AccountSession.usableToken("old", error: timedOut, expiresAt: valid, rejected: nil, now: now) == "old")
        #expect(throws: GmailError.transport(.timedOut)) {
            try AccountSession.usableToken("old", error: timedOut, expiresAt: now, rejected: nil, now: now)
        }
        #expect(throws: GmailError.transport(.badServerResponse)) {
            try AccountSession.usableToken("old", error: unavailable, expiresAt: valid, rejected: "old", now: now)
        }
    }

    @Test func grantFailuresPassThroughAFailedRefresh() {
        let invalidGrant = NSError(domain: OIDOAuthTokenErrorDomain, code: OIDErrorCodeOAuth.invalidGrant.rawValue)
        let noRefreshToken = NSError(domain: OIDGeneralErrorDomain, code: OIDErrorCode.tokenRefreshError.rawValue)
        for error in [invalidGrant, noRefreshToken] {
            let thrown = #expect(throws: (any Error).self) {
                try AccountSession.usableToken("old", error: error, expiresAt: .distantFuture, rejected: nil, now: .now)
            }
            #expect(thrown.map { $0 as NSError } == error)
        }
    }

    @Test func revocationSendsTheTokenInAFormBodyAndNeverInTheURL() async throws {
        let token = "1//synthetic+token/=&"
        let transport = RevocationTransport()
        #expect(await GoogleTokenRevocation(transport: transport).revoke(refreshToken: token))
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body == "token=1%2F%2Fsynthetic%2Btoken%2F%3D%26")
        var form = URLComponents()
        form.percentEncodedQuery = body
        #expect(form.queryItems == [URLQueryItem(name: "token", value: token)])
    }

    @Test(arguments: ["http://accounts.google.com/auth", "https://attacker.invalid/auth", "https://accounts.google.com.attacker.invalid/auth", "https://user@accounts.google.com/auth"])
    func browserAdapterRejectsUntrustedAuthorizationEndpoints(_ address: String) throws {
        var opened = false
        let browser = GoogleBrowserUserAgent(openBrowser: { _ in opened = true; return true })
        let service = OIDServiceConfiguration(authorizationEndpoint: URL(string: address)!, tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!)
        let request = OIDAuthorizationRequest(configuration: service, clientId: configuration.clientID,
            scopes: GoogleScopes.base, redirectURL: configuration.redirectURL, responseType: OIDResponseTypeCode,
            additionalParameters: nil)
        let session = OIDAuthState.authState(byPresenting: request, externalUserAgent: browser) { state, _ in
            #expect(state == nil)
        }
        #expect(!opened)
        session.cancel()
    }

    private func state(in url: URL) throws -> String {
        try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
    }

    private func callback(state: String?, duplicateState: Bool = false, path: String = "/oauthredirect") throws -> URL {
        var components = try #require(URLComponents(url: configuration.redirectURL, resolvingAgainstBaseURL: false))
        components.path = path
        var items = [URLQueryItem(name: "error", value: "access_denied"), URLQueryItem(name: "error_description", value: "synthetic-provider-private-detail")]
        if let state { items.append(.init(name: "state", value: state)) }
        if duplicateState, let state { items.append(.init(name: "state", value: state)) }
        components.queryItems = items
        return try #require(components.url)
    }
}

/// Keeps each request and answers 200, so nothing reaches Google.
private actor RevocationTransport: HTTPTransport {
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (Data(), response)
    }
}
