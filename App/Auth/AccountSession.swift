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
    /// Mail sync, search and settings clients share this account's quota.
    let gmailRequestBudget = GmailRequestBudget()

    /// Called when Google rejects the refresh token, for example after a
    /// testing-mode consent expires.
    var onSignInRequired: (@MainActor () -> Void)?

    private var authState: OIDAuthState?
    private var persistedAccessToken: String?
    /// The token a caller last asked to replace after a server turned it
    /// down. A failed refresh never falls back to it.
    private var rejectedAccessToken: String?
    private var credentialWrite: Task<Void, any Error>?
    private var credentialWriteRevision = 0

    /// A session from a sign-in, which `save()` stores. Without a state it
    /// waits for `replace(with:)`, and its client's requests ask for sign-in.
    init(accountID: String, state: OIDAuthState? = nil) {
        self.accountID = accountID
        authState = state
    }

    /// The saved session for `accountID`, or nil if there is none.
    static func restore(accountID: String) async -> AccountSession? {
        guard let data = try? await KeychainStore.load(account: accountID),
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
    func replace(with state: OIDAuthState) async throws {
        authState = state
        persistedAccessToken = nil
        rejectedAccessToken = nil
        try await persist(state)
    }

    func save() async throws {
        guard let authState else { return }
        try await persist(authState)
    }

    /// Forgets the session and deletes its Keychain item.
    func signOut() async {
        authState = nil
        persistedAccessToken = nil
        rejectedAccessToken = nil
        let write = enqueueCredentialWrite(nil)
        try? await write.task.value
    }

    /// Account removal owns durable credential deletion. Invalidate immediately
    /// and drain writes first so a late refresh cannot recreate its Keychain item.
    func invalidateForRemoval() async {
        authState = nil
        persistedAccessToken = nil
        rejectedAccessToken = nil
        _ = try? await credentialWrite?.value
    }

    /// Starts asking Google to revoke this session's grant. The request keeps
    /// its own copy of the refresh token, so removal can delete the stored one
    /// right away. Nil when the session holds no refresh token.
    func startRevokingGrant(using revocation: GoogleTokenRevocation) -> Task<Bool, Never>? {
        guard let token = authState?.refreshToken, !token.isEmpty else { return nil }
        return Task { await revocation.revoke(refreshToken: token) }
    }

    // MARK: AccessTokenProvider

    func accessToken(forceRefresh: Bool) async throws -> String {
        var forceRefresh = forceRefresh
        var retried = false
        while true {
            guard let state = authState else { throw GoogleAuth.AuthError.signInRequired }
            if forceRefresh {
                rejectedAccessToken = state.lastTokenResponse?.accessToken
                state.setNeedsTokenRefresh()
            }
            let result: Result<String, any Error>
            do {
                let token = try await freshToken(from: state)
                try Task.checkCancellation()
                if authState === state, token != persistedAccessToken {
                    try? await persist(state)
                }
                result = .success(token)
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
                return token
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == OIDOAuthTokenErrorDomain, nsError.code == OIDErrorCodeOAuth.invalidGrant.rawValue {
                    await signOut()
                    // Reauthorization may have completed while deletion waited.
                    // Its write follows the deletion and its state stays active.
                    if authState != nil {
                        guard !retried else { throw GoogleAuth.AuthError.signInRequired }
                        retried = true
                        forceRefresh = false
                        continue
                    }
                    onSignInRequired?()
                    throw GoogleAuth.AuthError.signInRequired
                }
                throw error
            }
        }
    }

    /// The token AppAuth's answer leaves usable. After a refresh fails with
    /// anything but an OAuth error, such as a timeout or a 5xx, AppAuth
    /// still hands back the old token. That token is used only while it is
    /// unexpired and isn't the one a server just turned down. Otherwise the
    /// failure becomes `GmailError.transport`, which callers retry. OAuth
    /// errors such as `invalid_grant` concern the grant, and a missing
    /// refresh token can't be retried, so both pass through.
    nonisolated static func usableToken(
        _ token: String?, error: (any Error)?, expiresAt: Date?, rejected: String?, now: Date
    ) throws -> String {
        guard let error else {
            guard let token else { throw GoogleAuth.AuthError.signInRequired }
            return token
        }
        let nsError = error as NSError
        let missingRefreshToken = nsError.domain == OIDGeneralErrorDomain
            && nsError.code == OIDErrorCode.tokenRefreshError.rawValue
        guard nsError.domain != OIDOAuthTokenErrorDomain, !missingRefreshToken else { throw error }
        if let token, token != rejected, let expiresAt, expiresAt > now { return token }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let code = underlying.flatMap { $0.domain == NSURLErrorDomain ? URLError.Code(rawValue: $0.code) : nil }
        throw GmailError.transport(code ?? .badServerResponse)
    }

    // MARK: Private

    private func freshToken(from state: OIDAuthState) async throws -> String {
        let answer: (token: String?, error: (any Error)?) = await withCheckedContinuation { continuation in
            state.performAction { accessToken, _, error in
                continuation.resume(returning: (accessToken, error))
            }
        }
        if answer.error == nil { rejectedAccessToken = nil }
        return try Self.usableToken(answer.token, error: answer.error,
            expiresAt: state.lastTokenResponse?.accessTokenExpirationDate, rejected: rejectedAccessToken, now: .now)
    }

    private func persist(_ state: OIDAuthState) async throws {
        guard authState === state else { throw CancellationError() }
        let data = try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true)
        let token = state.lastTokenResponse?.accessToken
        let write = enqueueCredentialWrite(data)
        do {
            try await write.task.value
        } catch {
            guard authState === state else { throw CancellationError() }
            throw error
        }
        guard authState === state else { throw CancellationError() }
        if credentialWriteRevision == write.revision { persistedAccessToken = token }
    }

    /// Record ordering on the main actor before awaiting any I/O. A refresh
    /// queued before sign-out must finish before the deletion, even if the
    /// executor schedules their continuations in a different order.
    private func enqueueCredentialWrite(_ data: Data?) -> (task: Task<Void, any Error>, revision: Int) {
        let previous = credentialWrite
        credentialWriteRevision += 1
        let task = Task { [accountID] in
            _ = try? await previous?.value
            if let data {
                try await KeychainStore.save(data, account: accountID)
            } else {
                try await KeychainStore.delete(account: accountID)
            }
        }
        credentialWrite = task
        return (task, credentialWriteRevision)
    }
}
