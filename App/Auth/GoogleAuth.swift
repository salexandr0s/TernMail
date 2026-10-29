import AppAuth
import AppAuthCore
import AppKit
import GmailAPI

/// Google OAuth for one account. Sign-in runs in `ASWebAuthenticationSession`,
/// the auth state is archived in the Keychain, and the API client asks this
/// object for fresh access tokens.
@MainActor
final class GoogleAuth: AccessTokenProvider {
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
    }

    enum AuthError: LocalizedError {
        case notConfigured
        case noWindow
        case missingIdentity
        case gmailAccessNotGranted
        case signInRequired

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No Google OAuth client is set up for this build."
            case .noWindow: "Open a Tern window, then try again."
            case .missingIdentity: "Google did not return your account details."
            case .gmailAccessNotGranted: "Tern needs permission to read and organize your Gmail. Sign in again and leave that box checked."
            case .signInRequired: "Your Google session expired. Sign in again."
            }
        }
    }

    static let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
    private static let scopes = [OIDScopeOpenID, OIDScopeEmail, OIDScopeProfile, gmailScope]

    /// Called when Google rejects the refresh token, for example after a
    /// testing-mode consent expires.
    var onSignInRequired: (@MainActor () -> Void)?

    private let configuration: Configuration?
    private var authState: OIDAuthState?
    private var keychainAccount: String?
    private var persistedAccessToken: String?
    private var session: (any OIDExternalUserAgentSession)?

    init(configuration: Configuration?) {
        self.configuration = configuration
    }

    var isConfigured: Bool { configuration != nil }

    /// Loads the saved session for `accountID`. Returns false if there is none.
    func restore(accountID: String) -> Bool {
        guard let data = try? KeychainStore.load(account: accountID),
              let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data),
              state.isAuthorized
        else { return false }
        authState = state
        keychainAccount = accountID
        persistedAccessToken = state.lastTokenResponse?.accessToken
        return true
    }

    func signIn() async throws -> SignedInUser {
        guard let configuration else { throw AuthError.notConfigured }
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { throw AuthError.noWindow }

        let request = OIDAuthorizationRequest(
            configuration: try Self.serviceConfiguration(),
            clientId: configuration.clientID,
            scopes: Self.scopes,
            redirectURL: configuration.redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )
        let state = try await present(request, from: window)

        guard let idTokenString = state.lastTokenResponse?.idToken,
              let idToken = OIDIDToken(idTokenString: idTokenString),
              let email = idToken.claims["email"] as? String
        else { throw AuthError.missingIdentity }
        let granted = (state.lastTokenResponse?.scope ?? "").split(separator: " ").map(String.init)
        guard granted.contains(Self.gmailScope) else { throw AuthError.gmailAccessNotGranted }

        authState = state
        keychainAccount = idToken.subject
        try persist(state)
        return SignedInUser(
            id: idToken.subject,
            email: email,
            displayName: idToken.claims["name"] as? String,
            grantedScopes: granted
        )
    }

    func signOut() {
        if let keychainAccount {
            try? KeychainStore.delete(account: keychainAccount)
        }
        authState = nil
        keychainAccount = nil
        persistedAccessToken = nil
    }

    // MARK: AccessTokenProvider

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let state = authState else { throw AuthError.signInRequired }
        if forceRefresh { state.setNeedsTokenRefresh() }
        do {
            let token = try await freshToken(from: state)
            if token != persistedAccessToken {
                try? persist(state)
            }
            return token
        } catch {
            let nsError = error as NSError
            if nsError.domain == OIDOAuthTokenErrorDomain, nsError.code == OIDErrorCodeOAuth.invalidGrant.rawValue {
                signOut()
                onSignInRequired?()
                throw AuthError.signInRequired
            }
            throw error
        }
    }

    // MARK: Private

    private func present(_ request: OIDAuthorizationRequest, from window: NSWindow) async throws -> OIDAuthState {
        defer { session = nil }
        let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthStateBox, any Error>) in
            session = OIDAuthState.authState(byPresenting: request, presenting: window) { state, error in
                if let state {
                    continuation.resume(returning: AuthStateBox(state: state))
                } else {
                    continuation.resume(throwing: error ?? AuthError.missingIdentity)
                }
            }
        }
        return box.state
    }

    private func freshToken(from state: OIDAuthState) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            state.performAction { accessToken, _, error in
                if let accessToken {
                    continuation.resume(returning: accessToken)
                } else {
                    continuation.resume(throwing: error ?? AuthError.signInRequired)
                }
            }
        }
    }

    private func persist(_ state: OIDAuthState) throws {
        guard let keychainAccount else { return }
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        try KeychainStore.save(data, account: keychainAccount)
        persistedAccessToken = state.lastTokenResponse?.accessToken
    }

    private static func serviceConfiguration() throws -> OIDServiceConfiguration {
        guard let authorization = URL(string: "https://accounts.google.com/o/oauth2/v2/auth"),
              let token = URL(string: "https://oauth2.googleapis.com/token")
        else { throw AuthError.notConfigured }
        return OIDServiceConfiguration(authorizationEndpoint: authorization, tokenEndpoint: token)
    }
}

/// Carries the new auth state out of AppAuth's completion handler, which runs
/// on the main thread, back to the main actor that started the sign-in.
private struct AuthStateBox: @unchecked Sendable {
    let state: OIDAuthState
}
