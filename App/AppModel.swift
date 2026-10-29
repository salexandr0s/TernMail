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
    /// Accounts whose Google session ended while the others carry on. With
    /// one account the window shows sign-in instead.
    private(set) var accountsNeedingSignIn: Set<String> = []
    /// Sign Out of every account, waiting for confirmation.
    var isConfirmingSignOut = false
    /// Sign Out of one of several accounts, waiting for confirmation.
    var accountToSignOut: AccountRecord?

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

            let signedIn = try await accounts.accounts()
            try await removeLeftovers(keeping: Set(signedIn.map(\.id)))
            guard let first = signedIn.first else {
                phase = .signedOut
                return
            }
            for account in signedIn {
                adopt(AccountSession.restore(accountID: account.id) ?? AccountSession(accountID: account.id))
            }
            let expired = signedIn.filter { sessions[$0.id]?.isSignedIn != true }
            if signedIn.count == 1, !expired.isEmpty {
                phase = .signInRequired(first)
                return
            }
            accountsNeedingSignIn = Set(expired.map(\.id))
            await openMailbox(for: signedIn)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Sign-in from the sign-in screen, including after the only account's
    /// session ended.
    func signIn() async {
        let returning: AccountRecord? = if case .signInRequired(let old) = phase { old } else { nil }
        await signIn(as: returning)
    }

    /// Sign-in for one of several accounts whose session ended.
    func signInAgain(to accountID: String) async {
        guard let owner = mailbox?.account(id: accountID) else { return }
        await signIn(as: owner.account)
    }

    /// Adds another Google account to the window. Signing in to one that's
    /// already added refreshes its session.
    func addAccount() async {
        await signIn(as: nil)
    }

    private func signIn(as returning: AccountRecord?) async {
        guard !isSigningIn, let accounts else { return }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
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
                reportSignInError("You signed in as \(account.email). Sign in as \(returning.email) to keep its drafts and unsent messages, or sign out of it first.")
                return
            }
            let session: AccountSession
            if let existing = sessions[account.id] {
                // Clients holding the session pick up the new tokens.
                try existing.replace(with: user.state)
                session = existing
            } else {
                session = AccountSession(accountID: account.id, state: user.state)
                try session.save()
                adopt(session)
            }
            try await accounts.save(account)
            accountsNeedingSignIn.remove(account.id)
            guard let mailbox else {
                await openMailbox(for: try await accounts.accounts())
                return
            }
            if let owner = mailbox.account(id: account.id) {
                // Back after the session ended: the open mailbox carries on.
                if case .signInRequired = phase { phase = .signedIn(mailbox.account) }
                owner.syncNow()
            } else {
                await mailbox.addAccount(account, gmail: GmailClient(tokens: session))
            }
        } catch is CancellationError {
            return
        } catch {
            reportSignInError(error.localizedDescription)
        }
    }

    /// The sign-in screen shows the error, or the window when it's open.
    private func reportSignInError(_ message: String) {
        if case .signedIn = phase, let mailbox {
            mailbox.notice = MailboxModel.Notice(message: message, isError: true)
        } else {
            signInError = message
        }
    }

    /// Signs out of every account.
    func signOut() async {
        guard let accounts else { return }
        await closeMailbox()
        sessions.values.forEach { $0.signOut() }
        sessions = [:]
        accountsNeedingSignIn = []
        do {
            for account in try await accounts.accounts() {
                try await removeAccountData(account, from: accounts)
            }
            // Only signed-in accounts keep downloaded attachments and the
            // files attached to their drafts.
            try? FileManager.default.removeItem(at: MailboxModel.defaultDownloadsDirectory)
            if let outgoingDirectory { try? FileManager.default.removeItem(at: outgoingDirectory) }
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Signs out of one account while the others stay. The last account
    /// signs out of Tern.
    func signOut(of accountID: String) async {
        guard let mailbox, mailbox.hasSeveralAccounts, let accounts, let owner = mailbox.account(id: accountID) else {
            await signOut()
            return
        }
        let account = owner.account
        await mailbox.removeAccount(id: accountID)
        sessions.removeValue(forKey: accountID)?.signOut()
        accountsNeedingSignIn.remove(accountID)
        phase = .signedIn(mailbox.account)
        if !mailbox.hasSeveralAccounts, accountsNeedingSignIn.remove(mailbox.account.id) != nil {
            // The account left needs sign-in, which one account shows in the window.
            phase = .signInRequired(mailbox.account)
        }
        do {
            try await removeAccountData(account, from: accounts)
        } catch {
            // Once its record is gone, the next launch deletes what's left.
            mailbox.notice = MailboxModel.Notice(message: "Tern couldn't delete everything it kept for \(account.email).", isError: true)
        }
    }

    var canSignOut: Bool {
        switch phase {
        case .signedIn, .signInRequired: true
        case .loading, .signedOut, .failed: false
        }
    }

    var signOutMessage: String {
        Self.signOutMessage(outbox: mailbox?.outbox.count ?? 0, snoozed: mailbox?.snoozed.count ?? 0)
    }

    /// The confirmation for one of several accounts, which counts only its own items.
    func signOutMessage(for account: AccountRecord) -> String {
        let owner = mailbox?.account(id: account.id)
        return Self.signOutMessage(outbox: owner?.outbox.count ?? 0, snoozed: owner?.snoozed.count ?? 0)
    }

    private static func signOutMessage(outbox: Int, snoozed: Int) -> String {
        let deletes = "Tern deletes the mail it downloaded and any changes it hasn't sent to Gmail yet"
        let message = switch outbox {
        case 0: deletes + "."
        case 1: deletes + ", including 1 message in the Outbox."
        case let count: deletes + ", including \(count) messages in the Outbox."
        }
        // Snoozes live on this Mac, so signing out ends them where they are.
        return switch snoozed {
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
    /// With several accounts only this one's section asks for sign-in.
    private func sessionExpired(_ accountID: String) {
        guard let mailbox, mailbox.account(id: accountID) != nil else { return }
        if mailbox.hasSeveralAccounts {
            accountsNeedingSignIn.insert(accountID)
        } else if case .signedIn(let account) = phase {
            phase = .signInRequired(account)
        }
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
        guard let cache, let accountIDs = mailbox?.accounts.map(\.account.id) else { return [] }
        return (try? await cache.read { tx in try accountIDs.flatMap { try tx.localDrafts(accountID: $0) } }) ?? []
    }

    /// Sends every waiting message now. False when one of them couldn't
    /// reach Gmail or Gmail refused it, or `timeout` passed first. A send still
    /// running after the timeout keeps going, and the next launch finishes one
    /// cut off by quitting.
    func sendWaitingMessages(timeout: Duration = .seconds(10)) async -> Bool {
        guard let engines = mailbox?.accounts.map(\.engine), !engines.isEmpty else { return true }
        let (outcome, continuation) = AsyncStream.makeStream(of: Bool.self)
        Task {
            let sent = await withTaskGroup(of: Bool.self) { group in
                for engine in engines { group.addTask { await engine.sendWaitingDraftsNow() } }
                var sent = true
                for await engineSent in group { sent = sent && engineSent }
                return sent
            }
            continuation.yield(sent)
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

    /// Opens the window's mailbox with every signed-in account, starting in
    /// the combined Inbox when there are several.
    private func openMailbox(for records: [AccountRecord]) async {
        guard let cache, let accounts, let outgoingDirectory,
              let first = records.first, let session = sessions[first.id]
        else { return }
        await closeMailbox()
        let mailbox = MailboxModel(
            account: first, cache: cache, gmail: GmailClient(tokens: session),
            outgoingDirectory: outgoingDirectory, snoozeStore: accounts
        )
        for record in records.dropFirst() {
            guard let session = sessions[record.id] else { continue }
            await mailbox.addAccount(record, gmail: GmailClient(tokens: session))
        }
        if mailbox.hasSeveralAccounts { mailbox.selectedMailbox = .combined(SystemLabel.inbox) }
        self.mailbox = mailbox
        phase = .signedIn(first)
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

    /// Deletes an account's record, snoozes, Keychain item, cache rows and
    /// files. The record goes first, so if this stops partway the next
    /// launch deletes the rest.
    private func removeAccountData(_ account: AccountRecord, from accounts: AccountStore) async throws {
        try await accounts.deleteAccount(id: account.id)
        // A session that failed to restore at launch can leave its item behind.
        try? KeychainStore.delete(account: account.id)
        try await removeCachedData(accountIDs: [account.id])
    }

    /// Deletes what the cache and disk still hold for accounts that aren't
    /// signed in, such as one whose sign-out stopped partway.
    private func removeLeftovers(keeping signedIn: Set<String>) async throws {
        guard let cache else { return }
        let stale = try await cache.read { tx in try tx.cachedAccountIDs() }.subtracting(signedIn)
        guard !stale.isEmpty else { return }
        try await removeCachedData(accountIDs: stale)
    }

    /// Deletes the accounts' cache rows, downloaded attachments and the files
    /// attached to their drafts, which only their local drafts lead to.
    private func removeCachedData(accountIDs: Set<String>) async throws {
        guard let cache else { return }
        let draftIDs = try await cache.write { tx in
            var draftIDs: [String] = []
            for accountID in accountIDs {
                draftIDs += try tx.localDrafts(accountID: accountID).map(\.id)
                try tx.deleteAccountData(accountID: accountID)
            }
            return draftIDs
        }
        for accountID in accountIDs {
            try? FileManager.default.removeItem(
                at: MailboxModel.defaultDownloadsDirectory.appending(path: accountID, directoryHint: .isDirectory)
            )
        }
        guard let outgoingDirectory else { return }
        for draftID in draftIDs {
            try? FileManager.default.removeItem(at: outgoingDirectory.appending(path: draftID, directoryHint: .isDirectory))
        }
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
