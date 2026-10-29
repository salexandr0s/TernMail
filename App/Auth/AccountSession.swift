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

    /// A session from a sign-in. `save()` stores it.
    init(accountID: String, state: OIDAuthState) {
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

    /// Takes the state from a new sign-in to this account and stores it.
    /// Clients holding this session carry on with it.
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
        guard let state = authState else { throw GoogleAuth.AuthError.signInRequired }
        if forceRefresh { state.setNeedsTokenRefresh() }
        do {
            let token = try await freshToken(from: state)
            try Task.checkCancellation()
            guard authState === state else { throw GoogleAuth.AuthError.signInRequired }
            if token != persistedAccessToken {
                try? persist(state)
            }
            return token
        } catch {
            // A refresh started before a new sign-in must not clear it.
            guard authState === state else { throw GoogleAuth.AuthError.signInRequired }
            let nsError = error as NSError
            if nsError.domain == OIDOAuthTokenErrorDomain, nsError.code == OIDErrorCodeOAuth.invalidGrant.rawValue {
                signOut()
                onSignInRequired?()
                throw GoogleAuth.AuthError.signInRequired
            }
            throw error
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
