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
    /// The open mailbox. It stays open while the session has expired, so
    /// compose windows keep working and queued changes wait for sign-in.
    private(set) var mailbox: MailboxModel?
    var isConfirmingSignOut = false

    let auth = GoogleAuth(configuration: .fromBundle())
    private(set) var cache: MailCache?
    private var accounts: AccountStore?
    /// Each signed-in account's tokens, by account ID.
    private var sessions: [String: AccountSession] = [:]
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
                // A second account with its own copy of the fake mail, so
                // both accounts hold the same thread and message IDs.
                let second = AccountRecord(id: "ui-audit-2", email: "second@example.invalid", displayName: "Second Audit", grantedScopes: [], addedAt: .now)
                try await accounts.save(account)
                try await accounts.save(second)
                self.cache = cache
                self.accounts = accounts
                let outgoing = FileManager.default.temporaryDirectory.appending(path: "Tern-UIAudit-Outgoing", directoryHint: .isDirectory)
                let mailbox = MailboxModel(
                    account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: outgoing, snoozeStore: accounts
                )
                self.mailbox = mailbox
                phase = .signedIn(account)
                Task {
                    await mailbox.addAccount(second, gmail: AuditGmail())
                    await mailbox.start()
                }
                return
            }
#endif
            let directory = try Self.dataDirectory()
            let accounts = try AccountStore.open(at: directory.appending(path: "config.sqlite"))
            // Off the main actor: the first open after an update can run a long
            // migration, such as indexing every cached message for search.
            let cacheURL = directory.appending(path: "cache.sqlite")
            cache = try await Task.detached(priority: .userInitiated) { try MailCache.open(at: cacheURL) }.value
            outgoingDirectory = directory.appending(path: "Outgoing", directoryHint: .isDirectory)
            self.accounts = accounts

            if let account = try await accounts.accounts().first {
                if let session = AccountSession.restore(accountID: account.id) {
                    adopt(session)
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
            let returning: AccountRecord? = if case .signInRequired(let old) = phase { old } else { nil }
            let user = try await auth.signIn(loginHint: returning?.email)
            let account = AccountRecord(
                id: user.id,
                email: user.email,
                displayName: user.displayName,
                grantedScopes: user.grantedScopes,
                addedAt: .now
            )
            if let returning, returning.id != account.id {
                // Replacing the account would delete its drafts and unsent
                // messages, so that takes Sign Out, which asks. The new
                // session is dropped unsaved, so nothing gets its tokens.
                signInError = "You signed in as \(account.email). Sign in as \(returning.email) to keep its drafts and unsent messages, or sign out of it first."
                return
            }
            if let session = sessions[account.id] {
                // Clients holding the session pick up the new tokens.
                try session.replace(with: user.state)
            } else {
                let session = AccountSession(accountID: account.id, state: user.state)
                try session.save()
                adopt(session)
            }
            if let mailbox, mailbox.account.id == account.id {
                // Back after the session expired: the open mailbox carries on.
                try await accounts.save(account)
                phase = .signedIn(account)
                mailbox.syncNow()
                return
            }
            // One account for now: signing in after a sign-out replaces any data left.
            await closeMailbox()
            for old in try await accounts.accounts() where old.id != account.id {
                sessions.removeValue(forKey: old.id)?.signOut()
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
        sessions.values.forEach { $0.signOut() }
        sessions = [:]
        do {
            for account in try await accounts.accounts() {
                try await removeAccountData(account, from: accounts)
            }
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    var canSignOut: Bool {
        switch phase {
        case .signedIn, .signInRequired: true
        case .loading, .signedOut, .failed: false
        }
    }

    var signOutMessage: String {
        let deletes = "Tern deletes the mail it downloaded and any changes it hasn't sent to Gmail yet"
        let message = switch mailbox?.outbox.count ?? 0 {
        case 0: deletes + "."
        case 1: deletes + ", including 1 message in the Outbox."
        case let count: deletes + ", including \(count) messages in the Outbox."
        }
        // Snoozes live on this Mac, so signing out ends them where they are.
        return switch mailbox?.snoozed.count ?? 0 {
        case 0: message
        case 1: message + " 1 snoozed conversation stays archived and won't return to the Inbox."
        case let count: message + " \(count) snoozed conversations stay archived and won't return to the Inbox."
        }
    }

    private func adopt(_ session: AccountSession) {
        let accountID = session.accountID
        session.onSignInRequired = { [weak self] in self?.sessionExpired(accountID) }
        sessions[accountID] = session
    }

    /// Saves, sends and label changes retry until the user signs in again.
    private func sessionExpired(_ accountID: String) {
        guard case .signedIn(let account) = phase, account.id == accountID else { return }
        phase = .signInRequired(account)
    }

    // MARK: Quitting

    /// Stores what open compose windows show, so quitting loses no typing.
    func prepareToQuit() async {
        await mailbox?.prepareToQuit()
    }

    /// Drafts whose send waits out its undo delay or a retry, which quitting
    /// sends at once. Read from the cache, since the Outbox can lag behind a
    /// send that just changed.
    func sendingDraftIDs() async -> Set<String> {
        Set(await localDrafts().filter { $0.state == .sending }.map(\.id))
    }

    /// How many of `ids` Gmail refused to send, which returns them to editing.
    func refusedDraftCount(among ids: Set<String>) async -> Int {
        await localDrafts().filter { ids.contains($0.id) && $0.state == .editing }.count
    }

    private func localDrafts() async -> [LocalDraft] {
        guard let cache, let accountID = mailbox?.account.id else { return [] }
        return (try? await cache.read { tx in try tx.localDrafts(accountID: accountID) }) ?? []
    }

    /// Sends every waiting message now. False when one of them couldn't
    /// reach Gmail or Gmail refused it, or `timeout` passed first. A send still
    /// running after the timeout keeps going, and the next launch finishes one
    /// cut off by quitting.
    func sendWaitingMessages(timeout: Duration = .seconds(10)) async -> Bool {
        guard let engine = mailbox?.engine else { return true }
        let (outcome, continuation) = AsyncStream.makeStream(of: Bool.self)
        Task {
            continuation.yield(await engine.sendWaitingDraftsNow())
            continuation.finish()
        }
        Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(false)
            continuation.finish()
        }
        for await sent in outcome { return sent }
        return false
    }

    private func openMailbox(for account: AccountRecord) async {
        guard let cache, let accounts, let outgoingDirectory, let session = sessions[account.id] else { return }
        await closeMailbox()
        let mailbox = MailboxModel(
            account: account, cache: cache, gmail: GmailClient(tokens: session),
            outgoingDirectory: outgoingDirectory, snoozeStore: accounts
        )
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
        // A session that failed to restore at launch can leave its item behind.
        try? KeychainStore.delete(account: account.id)
        // Only one account at a time keeps downloaded attachments and the
        // files attached to its drafts.
        try? FileManager.default.removeItem(at: MailboxModel.defaultDownloadsDirectory)
        if let outgoingDirectory { try? FileManager.default.removeItem(at: outgoingDirectory) }
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
