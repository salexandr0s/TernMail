import Foundation
import MailStore
import Observation

/// Composition root: opens the stores, restores the session and tracks the
/// signed-in account.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case signedOut
        /// The account is known but Google needs the user to sign in again.
        case signInRequired(AccountRecord)
        case signedIn(AccountRecord)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var isSigningIn = false
    private(set) var signInError: String?

    let auth = GoogleAuth(configuration: .fromBundle())
    private(set) var cache: MailCache?
    private var accounts: AccountStore?

    func start() async {
        guard phase == .loading else { return }
        do {
            let directory = try Self.dataDirectory()
            let accounts = try AccountStore.open(at: directory.appending(path: "config.sqlite"))
            cache = try MailCache.open(at: directory.appending(path: "cache.sqlite"))
            self.accounts = accounts
            auth.onSignInRequired = { [weak self] in self?.sessionExpired() }

            if let account = try await accounts.accounts().first {
                phase = auth.restore(accountID: account.id) ? .signedIn(account) : .signInRequired(account)
            } else {
                phase = .signedOut
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func signIn() async {
        guard !isSigningIn, let accounts else { return }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            let user = try await auth.signIn()
            let account = AccountRecord(
                id: user.id,
                email: user.email,
                displayName: user.displayName,
                grantedScopes: user.grantedScopes,
                addedAt: .now
            )
            // One account for now: a different Google account replaces the old one.
            for old in try await accounts.accounts() where old.id != account.id {
                try await removeAccountData(old, from: accounts)
            }
            try await accounts.save(account)
            phase = .signedIn(account)
        } catch {
            signInError = error.localizedDescription
        }
    }

    func signOut() async {
        guard let accounts else { return }
        auth.signOut()
        do {
            for account in try await accounts.accounts() {
                try await removeAccountData(account, from: accounts)
            }
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func sessionExpired() {
        if case .signedIn(let account) = phase {
            phase = .signInRequired(account)
        }
    }

    private func removeAccountData(_ account: AccountRecord, from accounts: AccountStore) async throws {
        try await cache?.write { tx in try tx.deleteAccountData(accountID: account.id) }
        try await accounts.deleteAccount(id: account.id)
    }

    private static func dataDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appending(path: "Tern", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
