import Foundation
import GmailAPI
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
    /// The open mailbox while signed in.
    private(set) var mailbox: MailboxModel?
    var isConfirmingSignOut = false

    let auth = GoogleAuth(configuration: .fromBundle())
    private(set) var cache: MailCache?
    private var accounts: AccountStore?
    /// Copies of the files attached to drafts, kept until the draft is sent or discarded.
    private var outgoingDirectory: URL?
    /// Mailboxes still stopping, so data is deleted only after they finish.
    private var closing: Task<Void, Never>?

    func start() async {
        guard phase == .loading else { return }
        do {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
                let cache = try MailCache.inMemory()
                let accounts = try AccountStore.inMemory()
                let account = AccountRecord(id: "ui-audit", email: "audit@example.invalid", displayName: "UI Audit", grantedScopes: [], addedAt: .now)
                try await accounts.save(account)
                self.cache = cache
                self.accounts = accounts
                let outgoing = FileManager.default.temporaryDirectory.appending(path: "Tern-UIAudit-Outgoing", directoryHint: .isDirectory)
                let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: outgoing)
                self.mailbox = mailbox
                phase = .signedIn(account)
                Task { await mailbox.start() }
                return
            }
#endif
            let directory = try Self.dataDirectory()
            let accounts = try AccountStore.open(at: directory.appending(path: "config.sqlite"))
            cache = try MailCache.open(at: directory.appending(path: "cache.sqlite"))
            outgoingDirectory = directory.appending(path: "Outgoing", directoryHint: .isDirectory)
            self.accounts = accounts
            auth.onSignInRequired = { [weak self] in self?.sessionExpired() }

            if let account = try await accounts.accounts().first {
                if auth.restore(accountID: account.id) {
                    await openMailbox(for: account)
                } else {
                    phase = .signInRequired(account)
                }
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
            await closeMailbox()
            for old in try await accounts.accounts() where old.id != account.id {
                try await removeAccountData(old, from: accounts)
            }
            try await accounts.save(account)
            await openMailbox(for: account)
        } catch {
            signInError = error.localizedDescription
        }
    }

    func signOut() async {
        guard let accounts else { return }
        await closeMailbox()
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
        guard case .signedIn(let account) = phase else { return }
        phase = .signInRequired(account)
        Task { await closeMailbox() }
    }

    private func openMailbox(for account: AccountRecord) async {
        guard let cache, let outgoingDirectory else { return }
        await closeMailbox()
        let mailbox = MailboxModel(account: account, cache: cache, gmail: GmailClient(tokens: auth), outgoingDirectory: outgoingDirectory)
        self.mailbox = mailbox
        phase = .signedIn(account)
        Task { await mailbox.start() }
    }

    /// Stops the open mailbox and waits for every mailbox still stopping.
    private func closeMailbox() async {
        if let mailbox {
            self.mailbox = nil
            let previous = closing
            closing = Task {
                await previous?.value
                await mailbox.stop()
            }
        }
        await closing?.value
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
