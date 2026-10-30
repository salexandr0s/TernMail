import AppAuth
import AppAuthCore
import Foundation
import GmailAPI

/// One account's Google session. It owns the account's Keychain item and
/// gives the API client fresh access tokens, so an expired session blocks
/// only its own account.
@MainActor
final class AccountSession: AccessTokenProvider {
    let accountID: String

    /// Called when Google rejects the refresh token, for example after a
    /// testing-mode consent expires.
    var onSignInRequired: (@MainActor () -> Void)?

    private var authState: OIDAuthState?
    private var persistedAccessToken: String?

    /// A session from a sign-in, which `save()` stores. Without a state it
    /// waits for `replace(with:)`, and its client's requests ask for sign-in.
    init(accountID: String, state: OIDAuthState? = nil) {
        self.accountID = accountID
        authState = state
    }

    /// The saved session for `accountID`, or nil if there is none.
    static func restore(accountID: String) -> AccountSession? {
        guard let data = try? KeychainStore.load(account: accountID),
              let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data),
              state.isAuthorized
        else { return nil }
        let session = AccountSession(accountID: accountID, state: state)
        session.persistedAccessToken = state.lastTokenResponse?.accessToken
        return session
    }

    var isSignedIn: Bool { authState != nil }

    /// The scopes the stored grant covers. Nil without a session.
    var grantedScopes: [String]? {
        authState.map { ($0.scope ?? "").split(separator: " ").map(String.init) }
    }

    /// The `hd` claim of the stored ID token. Nil for personal accounts, and
    /// when the last token response carried no ID token.
    var idTokenHostedDomain: String? {
        guard let idToken = authState?.lastTokenResponse?.idToken.flatMap(OIDIDToken.init(idTokenString:)) else { return nil }
        return idToken.claims["hd"] as? String
    }

    /// Swaps in the state from a new authorization of this account, then
    /// stores it. Clients holding this session use it from their next token
    /// request, and a request already waiting retries with it.
    func replace(with state: OIDAuthState) throws {
        authState = state
        try persist(state)
    }

    func save() throws {
        guard let authState else { return }
        try persist(authState)
    }

    /// Forgets the session and deletes its Keychain item.
    func signOut() {
        try? KeychainStore.delete(account: accountID)
        authState = nil
        persistedAccessToken = nil
    }

    // MARK: AccessTokenProvider

    func accessToken(forceRefresh: Bool) async throws -> String {
        var forceRefresh = forceRefresh
        var retried = false
        while true {
            guard let state = authState else { throw GoogleAuth.AuthError.signInRequired }
            if forceRefresh { state.setNeedsTokenRefresh() }
            let result: Result<String, any Error>
            do {
                result = .success(try await freshToken(from: state))
            } catch {
                result = .failure(error)
            }
            try Task.checkCancellation()
            guard authState === state else {
                // A new authorization replaced the state while this request
                // waited, so its outcome, a failed refresh included, belongs
                // to the old grant. The new tokens need no forced refresh.
                // After a sign-out, or a second swap, sign-in is reported.
                guard !retried, authState != nil else { throw GoogleAuth.AuthError.signInRequired }
                retried = true
                forceRefresh = false
                continue
            }
            switch result {
            case .success(let token):
                if token != persistedAccessToken {
                    try? persist(state)
                }
                return token
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == OIDOAuthTokenErrorDomain, nsError.code == OIDErrorCodeOAuth.invalidGrant.rawValue {
                    signOut()
                    onSignInRequired?()
                    throw GoogleAuth.AuthError.signInRequired
                }
                throw error
            }
        }
    }

    // MARK: Private

    private func freshToken(from state: OIDAuthState) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            state.performAction { accessToken, _, error in
                if let accessToken {
                    continuation.resume(returning: accessToken)
                } else {
                    continuation.resume(throwing: error ?? GoogleAuth.AuthError.signInRequired)
                }
            }
        }
    }

    private func persist(_ state: OIDAuthState) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        try KeychainStore.save(data, account: accountID)
        persistedAccessToken = state.lastTokenResponse?.accessToken
    }
}
