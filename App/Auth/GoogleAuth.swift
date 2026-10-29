import AppAuth
import AppAuthCore
import AppKit
import GmailAPI

/// Google sign-in. It runs in `ASWebAuthenticationSession` and hands back
/// an `AccountSession`, which keeps the account's tokens.
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

    enum AuthError: LocalizedError {
        case notConfigured
        case noWindow
        case missingIdentity
        case gmailAccessNotGranted
        case otherAccount
        case signInRequired

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No Google OAuth client is set up for this build."
            case .noWindow: "Open a Tern window, then try again."
            case .missingIdentity: "Google did not return your account details."
            case .gmailAccessNotGranted: "Tern needs permission to read and organize your Gmail. Sign in again and leave that box checked."
            case .otherAccount: "You chose a different Google account, so nothing changed. Try again and choose the same account."
            case .signInRequired: "Your Google session expired. Sign in again."
            }
        }
    }

    private let configuration: Configuration?
    private var session: (any OIDExternalUserAgentSession)?

    init(configuration: Configuration?) {
        self.configuration = configuration
    }

    var isConfigured: Bool { configuration != nil }

    /// Asks Google for an account with `features` on. Installed apps can't
    /// add scopes to a grant, so each authorization asks for all of them.
    /// `loginHint` suggests the account by address or `sub`. With
    /// `accountID`, a grant from another account is refused, as when a
    /// feature is turned on. The caller decides whether to keep the session.
    func signIn(
        loginHint: String? = nil, accountID: String? = nil,
        features: Set<AccountFeature> = [], isWorkspace: Bool = false
    ) async throws -> SignedInUser {
        guard let configuration else { throw AuthError.notConfigured }
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { throw AuthError.noWindow }

        let request = OIDAuthorizationRequest(
            configuration: try Self.serviceConfiguration(),
            clientId: configuration.clientID,
            scopes: GoogleScopes.request(features: features, isWorkspace: isWorkspace),
            redirectURL: configuration.redirectURL,
            responseType: OIDResponseTypeCode,
            additionalParameters: loginHint.map { ["login_hint": $0] }
        )
        let state = try await present(request, from: window)

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

    private func present(_ request: OIDAuthorizationRequest, from window: NSWindow) async throws -> OIDAuthState {
        defer { session = nil }
        let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AuthStateBox, any Error>) in
            session = OIDAuthState.authState(byPresenting: request, presenting: window) { state, error in
                if let state {
                    continuation.resume(returning: AuthStateBox(state: state))
                } else if let error = error as NSError?, error.domain == OIDGeneralErrorDomain,
                          error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue {
                    // Closing Google's page isn't a failure to report.
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: error ?? AuthError.missingIdentity)
                }
            }
        }
        return box.state
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
