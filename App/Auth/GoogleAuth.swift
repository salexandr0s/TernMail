import AppAuth
import AppAuthCore
import AppKit
import GmailAPI

/// Google sign-in through the default browser. AppAuth owns the authorization
/// request, callback validation and token exchange.
@MainActor
final class GoogleAuth {
    struct Configuration {
        let clientID: String
        let redirectURL: URL

        /// Reads the client from Info.plist, which takes it from `Config/Secrets.xcconfig`.
        static func fromBundle(_ bundle: Bundle = .main) -> Configuration? {
            guard let prefix = bundle.object(forInfoDictionaryKey: "TernGoogleClientIDPrefix") as? String,
                  !prefix.isEmpty,
                  let clientID = bundle.object(forInfoDictionaryKey: "TernGoogleClientID") as? String,
                  let scheme = bundle.object(forInfoDictionaryKey: "TernGoogleRedirectScheme") as? String,
                  let redirectURL = URL(string: "\(scheme):/oauthredirect")
            else { return nil }
            return Configuration(clientID: clientID, redirectURL: redirectURL)
        }
    }

    struct SignedInUser {
        let id: String
        let email: String
        let displayName: String?
        let grantedScopes: [String]
        /// The ID token's `hd` claim, which only Workspace accounts have.
        let hostedDomain: String?
        /// The features asked for that the grant covers.
        let grant: FeatureGrant
        /// The new session, not yet saved to the Keychain.
        let state: OIDAuthState
    }

    enum AuthError: LocalizedError, Equatable {
        case notConfigured
        case missingIdentity
        case missingRefreshToken
        case gmailAccessNotGranted
        case otherAccount
        case signInRequired
        case alreadySigningIn
        case browserUnavailable
        case timedOut
        case authorizationFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Google sign-in is unavailable in this version."
            case .missingIdentity: "Google did not return your account details."
            case .missingRefreshToken: "Google didn't allow Tern to stay signed in. Try again and approve the requested access."
            case .gmailAccessNotGranted: "Sign in again and allow Tern to read and organize your Gmail."
            case .otherAccount: "You chose a different Google account, so nothing changed. Try again and choose the same account."
            case .signInRequired: "Your Google session expired. Sign in again."
            case .alreadySigningIn: "Google sign-in is already open in your browser."
            case .browserUnavailable: "Tern couldn't open your browser. Try again."
            case .timedOut: "Google sign-in timed out. Try again."
            case .authorizationFailed: "Google sign-in didn't finish. Try again."
            }
        }
    }

    private let configuration: Configuration?
    private let openBrowser: @MainActor (URL) -> Bool
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var flow: PendingFlow?

    init(
        configuration: Configuration?,
        openBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        timeout: Duration = .seconds(300),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.openBrowser = openBrowser
        self.timeout = timeout
        self.sleep = sleep
    }

    var isConfigured: Bool { configuration != nil }

    /// OAuth URLs never enter the mail-link queue, including callbacks from
    /// closed or completed attempts. AppAuth validates the active callback.
    @discardableResult
    func handleRedirect(_ url: URL) -> Bool {
        guard let scheme = configuration?.redirectURL.scheme,
              url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame else { return false }
        guard url.absoluteString.utf8.count <= 65_536, let flow,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let expectedState = flow.request.state else { return true }
        let states = items.filter { $0.name == "state" }
        // A late response from a cancelled tab must not fail a newer flow.
        guard states.count == 1, states.first?.value == expectedState else { return true }
        _ = try? flow.session?.resumeExternalUserAgentFlow(url)
        return true
    }

    func cancelSignIn() {
        guard let flow else { return }
        finish(flow.id, result: .failure(CancellationError()), cancelSession: true)
    }

    /// Asks Google for an account with `features` on. Installed apps can't
    /// add scopes to a grant, so each authorization asks for all of them.
    /// `loginHint` suggests the account by address or `sub`. With
    /// `accountID`, a grant from another account is refused, as when a
    /// feature is turned on. The caller decides whether to keep the session.
    func signIn(
        loginHint: String? = nil, accountID: String? = nil,
        features: Set<AccountFeature> = [], isWorkspace: Bool = false
    ) async throws -> SignedInUser {
        let request = try authorizationRequest(loginHint: loginHint, features: features, isWorkspace: isWorkspace)
        let state = try await present(request)
        return try Self.signedInUser(state: state, accountID: accountID, features: features)
    }

    func authorizationRequest(
        loginHint: String? = nil, features: Set<AccountFeature> = [], isWorkspace: Bool = false
    ) throws -> OIDAuthorizationRequest {
        guard let configuration else { throw AuthError.notConfigured }
        // Every explicit authorization creates a replacement state. Re-consent
        // requests a refresh token even when the account granted access before.
        var parameters = ["access_type": "offline", "prompt": "consent"]
        if let loginHint { parameters["login_hint"] = loginHint }
        return OIDAuthorizationRequest(
            configuration: try Self.serviceConfiguration(),
            clientId: configuration.clientID,
            scopes: GoogleScopes.request(features: features, isWorkspace: isWorkspace),
            redirectURL: configuration.redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: parameters
        )
    }

    static func signedInUser(
        state: OIDAuthState, accountID: String?, features: Set<AccountFeature>
    ) throws -> SignedInUser {
        guard let idTokenString = state.lastTokenResponse?.idToken,
              let idToken = OIDIDToken(idTokenString: idTokenString),
              let email = idToken.claims["email"] as? String
        else { throw AuthError.missingIdentity }
        // AppAuth preserves the effective grant when a token response omits
        // scope (OAuth defines an omitted scope as unchanged).
        let granted = (state.scope ?? "").split(separator: " ").map(String.init)
        let grant: FeatureGrant
        do {
            grant = try FeatureGrant(subject: idToken.subject, granted: granted, accountID: accountID, features: features)
        } catch FeatureGrant.Rejection.otherAccount {
            throw AuthError.otherAccount
        } catch FeatureGrant.Rejection.mailAccessNotGranted {
            throw AuthError.gmailAccessNotGranted
        }
        guard state.refreshToken?.isEmpty == false else { throw AuthError.missingRefreshToken }

        return SignedInUser(
            id: idToken.subject,
            email: email,
            displayName: idToken.claims["name"] as? String,
            grantedScopes: granted,
            hostedDomain: idToken.claims["hd"] as? String,
            grant: grant,
            state: state
        )
    }

    // MARK: Private

    private func present(_ request: OIDAuthorizationRequest) async throws -> OIDAuthState {
        try Task.checkCancellation()
        guard flow == nil else { throw AuthError.alreadySigningIn }
        let id = UUID()
        let box = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthStateBox, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let pending = PendingFlow(id: id, request: request, continuation: continuation)
                flow = pending
                pending.timer = Task { [weak self, sleep, timeout] in
                    do { try await sleep(timeout); try Task.checkCancellation() }
                    catch { return }
                    self?.finish(id, result: .failure(AuthError.timedOut), cancelSession: true)
                }
                let browser = GoogleBrowserUserAgent(openBrowser: openBrowser)
                let session = OIDAuthState.authState(byPresenting: request, externalUserAgent: browser) { [weak self] state, error in
                    // AppAuth delivers this callback on the main queue.
                    MainActor.assumeIsolated {
                        let result = state.map { Result<AuthStateBox, any Error>.success(AuthStateBox(state: $0)) }
                            ?? .failure(Self.authorizationError(error))
                        self?.finish(id, result: result)
                    }
                }
                if flow?.id == id { pending.session = session }
                else { session.cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, result: .failure(CancellationError()), cancelSession: true)
            }
        }
        try Task.checkCancellation()
        return box.state
    }

    private func finish(_ id: UUID, result: Result<AuthStateBox, any Error>, cancelSession: Bool = false) {
        guard let pending = flow, pending.id == id else { return }
        flow = nil
        pending.timer?.cancel()
        if cancelSession { pending.session?.cancel() }
        pending.continuation.resume(with: result)
    }

    private static func authorizationError(_ error: (any Error)?) -> any Error {
        if let error = error as NSError?, error.domain == OIDGeneralErrorDomain {
            switch error.code {
            case OIDErrorCode.userCanceledAuthorizationFlow.rawValue,
                 OIDErrorCode.programCanceledAuthorizationFlow.rawValue:
                return CancellationError()
            case OIDErrorCode.safariOpenError.rawValue, OIDErrorCode.browserOpenError.rawValue:
                return AuthError.browserUnavailable
            default: break
            }
        }
        // Provider error descriptions may contain callback parameters.
        return AuthError.authorizationFailed
    }

    private final class PendingFlow {
        let id: UUID
        let request: OIDAuthorizationRequest
        let continuation: CheckedContinuation<AuthStateBox, any Error>
        var session: (any OIDExternalUserAgentSession)?
        var timer: Task<Void, Never>?

        init(id: UUID, request: OIDAuthorizationRequest, continuation: CheckedContinuation<AuthStateBox, any Error>) {
            self.id = id
            self.request = request
            self.continuation = continuation
        }
    }

    private static func serviceConfiguration() throws -> OIDServiceConfiguration {
        guard let authorization = URL(string: "https://accounts.google.com/o/oauth2/v2/auth"),
              let token = URL(string: "https://oauth2.googleapis.com/token")
        else { throw AuthError.notConfigured }
        return OIDServiceConfiguration(authorizationEndpoint: authorization, tokenEndpoint: token)
    }
}

/// AppAuth calls this adapter on the main actor where GoogleAuth starts and
/// resumes the flow. The adapter only opens the browser; AppAuth validates OAuth.
@MainActor
final class GoogleBrowserUserAgent: NSObject, @preconcurrency OIDExternalUserAgent {
    private let openBrowser: @MainActor (URL) -> Bool
    private var isPresenting = false

    init(openBrowser: @escaping @MainActor (URL) -> Bool) { self.openBrowser = openBrowser }

    func present(_ request: any OIDExternalUserAgentRequest, session: any OIDExternalUserAgentSession) -> Bool {
        guard !isPresenting, let url = request.externalUserAgentRequestURL(),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "accounts.google.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        isPresenting = true
        return openBrowser(url)
    }

    func dismiss(animated: Bool, completion: @escaping @Sendable () -> Void) {
        isPresenting = false
        completion()
    }
}

/// Carries the new auth state out of AppAuth's completion handler, which runs
/// on the main thread, back to the main actor that started the sign-in.
private struct AuthStateBox: @unchecked Sendable {
    let state: OIDAuthState
}
