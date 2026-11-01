import AppKit
import Foundation
import GmailAPI
import IMAPIdle
import MailStore
import Observation
import SyncEngine

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
    @ObservationIgnored private var assistantModel: AssistantModel?
    @ObservationIgnored private var calendarModel: CalendarModel?
    private(set) var accountPreferences: AccountPreferencesModel?
    private(set) var mailNotifications: MailNotificationCoordinator?
    private(set) var isResettingCache = false
    private(set) var visibleConversationKeys: Set<ThreadKey> = []
    @ObservationIgnored private var visibleConversationCounts: [ThreadKey: Int] = [:]
    @ObservationIgnored private var maintenanceModel: CacheMaintenanceModel?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var mailURLRouter: MailURLRouter?
    @ObservationIgnored private var spotlightIndexer: MailSpotlightIndexer?
    @ObservationIgnored private var mailBadges: MailBadgeController?
    @ObservationIgnored private var preferenceReconciliation: Task<Void, Never>?
    var destination: WorkspaceDestination = .mail
    @ObservationIgnored var assistantNavigationTask: Task<Void, Never>?
    /// Set by the main window's root view. The Dock, notifications and a
    /// Dock-icon click with no window open use it to show the window again.
    @ObservationIgnored var openMainWindow: (@MainActor () -> Void)? {
        didSet { CalendarNotificationRouter.shared.openMainWindow = openMainWindow }
    }

    func showMainWindow() { openMainWindow?() }

    /// The Dock menu's New Message: the main window opens the draft's window.
    func composeFromDock() {
        showMainWindow()
        guard let mailbox else { return }
        Task { if let id = await mailbox.startCompose(.newMessage) { mailbox.draftToReopen = id } }
    }

    var mailURLs: MailURLRouter {
        if let mailURLRouter { return mailURLRouter }
        let router = MailURLRouter(app: self)
        mailURLRouter = router
        return router
    }

    private var spotlight: MailSpotlightIndexer {
        if let spotlightIndexer { return spotlightIndexer }
        let indexer = MailSpotlightIndexer(app: self)
        spotlightIndexer = indexer
        return indexer
    }

    var maintenance: CacheMaintenanceModel {
        if let maintenanceModel { return maintenanceModel }
        let model = CacheMaintenanceModel(app: self)
        maintenanceModel = model
        return model
    }

    func conversationBecameVisible(_ key: ThreadKey) {
        visibleConversationCounts[key, default: 0] += 1
        visibleConversationKeys.insert(key)
    }

    func conversationStoppedBeingVisible(_ key: ThreadKey) {
        let remaining = max(0, visibleConversationCounts[key, default: 0] - 1)
        if remaining == 0 { visibleConversationCounts.removeValue(forKey: key); visibleConversationKeys.remove(key) }
        else { visibleConversationCounts[key] = remaining }
    }

    private func startCacheMaintenance() {
        guard maintenanceTask == nil, !ProcessInfo.processInfo.arguments.contains("--ui-audit") else { return }
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                guard let self else { return }
                guard mailbox != nil, !isResettingCache, !inboxUpdatesAreStopped else { continue }
                await maintenance.enforceBudget()
            }
        }
    }

    /// Reset keeps config and Calendar data. The final database transaction
    /// rechecks recoverable work after all mailbox writers have stopped.
    func resetMailCache() async throws {
        guard !isResettingCache, !isSigningIn, let cache, let accounts else { return }
        let readiness = try await cache.cacheResetReadiness()
        guard readiness.canReset else { throw CacheMaintenanceError.recoverableWork(readiness) }
        isResettingCache = true
        await maintenance.suspend()
        defer { isResettingCache = false; maintenance.resume(); startCacheMaintenance() }
        let previousMaintenance = maintenanceTask
        maintenanceTask = nil
        previousMaintenance?.cancel()
        await previousMaintenance?.value
        try await changeAccounts(returning: { [self] in
            let records = try await accounts.accounts()
            let downloadedAttachments = mailbox?.downloadsDirectory
            let categories = try await cache.attachmentCategorySnapshot()
            try await accounts.importAttachmentCategoryOverrides(categories)
            inboxUpdatesAreStopped = true
            await closeMailbox()
            spotlight.removeAll()
            do {
                try await cache.resetDisposableCache()
                await DomainLogoImages.shared.removeAll()
                if let downloadedAttachments { try? FileManager.default.removeItem(at: downloadedAttachments) }
                try? await cache.compactDisposableCache()
                inboxUpdatesAreStopped = false
                await openMailbox(for: records)
            } catch {
                inboxUpdatesAreStopped = false
                await openMailbox(for: records)
                throw error
            }
        })
    }

    private func startMailPreferences(store: AccountStore, cache: MailCache) async {
        guard accountPreferences == nil else { return }
        let defaults: UserDefaults
        if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
            defaults = UserDefaults(suiteName: "tern.audit.runtime.\(UUID().uuidString)") ?? .standard
        } else { defaults = .standard }
        let preferences = AccountPreferencesModel(store: store, defaults: defaults)
        accountPreferences = preferences
        mailNotifications = MailNotificationCoordinator(store: store, cache: cache, preferences: preferences, defaults: defaults)
        let badges = MailBadgeController(defaults: defaults)
        badges.onOpenInbox = { [weak self] accountID in self?.showInbox(accountID: accountID) }
        badges.onCheckForNewMail = { [weak self] in self?.mailbox?.syncNow() }
        badges.onNewMessage = { [weak self] in self?.composeFromDock() }
        badges.onOpenApp = { [weak self] in self?.showMainWindow() }
        mailBadges = badges
        preferences.onChange = { [weak self] in self?.schedulePreferenceReconciliation() }
        await preferences.start()
    }

    private func bindMailNotificationRoutes() {
        MailNotificationRouter.shared.isOnScreen = { [weak self] key in self?.isConversationOnScreen(key) ?? false }
        MailNotificationRouter.shared.bind { [weak self] target in await self?.routeMailNotification(target) }
    }

    /// A conversation window has it open, or the mailbox shows it selected.
    private func isConversationOnScreen(_ key: ThreadKey) -> Bool {
        if visibleConversationKeys.contains(key) { return true }
        guard destination == .mail, let mailbox else { return false }
        return mailbox.selectedThreadIDs.contains(key)
    }

    private func configureMailRuntime(_ owner: AccountMailbox) {
        owner.onMailSync = { [weak self] snapshot in
            self?.spotlight.mailSynced(accountID: snapshot.accountID)
            await self?.mailNotifications?.process(snapshot)
        }
        owner.onUnreadCountChange = { [weak self] in self?.refreshMailBadges() }
        owner.activityGuard = activityGuard
        owner.setActivity(syncActivity)
    }

    /// In front, the app checks for mail every 15 seconds; behind another
    /// window, every minute; while the Mac sleeps, not at all. Coming to the
    /// front checks at once.
    private func observeActivity() {
        guard activityObservers.isEmpty else { return }
        let application = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, in center: NotificationCenter, _ change: @escaping @MainActor (AppModel) -> Void) -> any NSObjectProtocol {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Delivered on the main queue, as requested above.
                MainActor.assumeIsolated { if let self { change(self) } }
            }
        }
        activityObservers = [
            observe(NSApplication.didBecomeActiveNotification, in: application) { $0.updateSyncActivity() },
            observe(NSApplication.didResignActiveNotification, in: application) { $0.updateSyncActivity() },
            observe(NSWorkspace.willSleepNotification, in: workspace) { $0.isMacAsleep = true; $0.updateSyncActivity() },
            observe(NSWorkspace.didWakeNotification, in: workspace) { $0.isMacAsleep = false; $0.updateSyncActivity() },
        ]
        updateSyncActivity()
    }

    private func updateSyncActivity() {
        let activity: SyncActivity = isMacAsleep ? .suspended : NSApplication.shared.isActive ? .active : .inactive
        guard activity != syncActivity else { return }
        syncActivity = activity
        for owner in mailbox?.accounts ?? [] { owner.setActivity(activity) }
    }

    private func schedulePreferenceReconciliation() {
        let previous = preferenceReconciliation
        preferenceReconciliation = Task { [weak self] in
            await previous?.value
            guard let self, let mailbox, let preferences = accountPreferences, !inboxUpdatesAreStopped else { return }
            mailbox.applyAccountPresentation(preferences: Array(preferences.preferencesByID.values), visibleAccountIDs: preferences.visibleAccountIDs)
            for record in preferences.orderedRecords {
                guard self.mailbox === mailbox, !inboxUpdatesAreStopped else { return }
                guard let owner = mailbox.account(id: record.id), let gmail = mailboxService(for: record.id) else { continue }
                let enabled = preferences.preferences(for: record.id).syncEnabled
                if owner.syncEnabled != enabled {
                    mailNotifications?.prepareAccount(record.id)
                    await inboxWatchers.removeValue(forKey: record.id)?.stop()
                    await mailbox.replaceAccountRuntime(record: record, gmail: gmail, syncEnabled: enabled)
                    if let replacement = mailbox.account(id: record.id) { configureMailRuntime(replacement) }
                }
            }
            await refreshInboxUpdates()
            refreshMailBadges()
        }
    }

    private func refreshMailBadges() {
        guard let mailbox else { mailBadges?.update(accounts: []); return }
        let records = accountPreferences?.orderedRecords ?? mailbox.accounts.map(\.account)
        let visible = accountPreferences?.visibleAccountIDs ?? Set(records.map(\.id))
        let accounts = records.filter { visible.contains($0.id) }.compactMap { record -> MailBadgeController.AccountUnread? in
            guard let owner = mailbox.account(id: record.id) else { return nil }
            return .init(id: record.id, title: accountPreferences?.displayName(for: record) ?? record.email,
                         count: owner.labels.first { $0.id == SystemLabel.inbox }?.threadsUnread ?? 0)
        }
        mailBadges?.update(accounts: accounts)
    }

    /// The menu bar item's Inbox rows: every account's Inbox, or one account's.
    private func showInbox(accountID: String?) {
        showMainWindow()
        destination = .mail
        guard let mailbox else { return }
        if let accountID {
            mailbox.search.clear()
            mailbox.selectedMailbox = .account(accountID, SystemLabel.inbox)
        } else {
            mailbox.go(to: SystemLabel.inbox)
        }
    }

    private func routeMailNotification(_ target: MailNotificationRouter.Target) async {
        guard let mailbox, let owner = mailbox.account(id: target.accountID) else { return }
        switch target.response {
        case .open:
            mailURLs.openConversation(.init(accountID: target.accountID, threadID: target.threadID, messageID: target.messageID))
        case .reply:
            // The main window opens the reply's own window, as the Dock's New Message does.
            showMainWindow()
            guard let id = await mailbox.requestReply(.reply, messageID: target.messageID, accountID: target.accountID, selectedText: nil) else { return }
            mailbox.draftToReopen = id
        case .perform(let action):
            do {
                switch action {
                case .archive: _ = try await owner.engine.perform(.archive, target: .messages([target.messageID]))
                case .trash: _ = try await owner.engine.perform(.trash, target: .messages([target.messageID]))
                case .markRead: _ = try await owner.engine.perform(.markRead, target: .messages([target.messageID]))
                case .star: _ = try await owner.engine.perform(.star, target: .messages([target.messageID]))
                }
            } catch { mailbox.notice = .init(message: "Couldn't apply the notification action. Try again in Tern.", isError: true) }
        }
    }

    /// All assistant presentations share one conversation and ChatGPT connection.
    var assistant: AssistantModel {
        if let assistantModel { return assistantModel }
        let value = AssistantModel(app: self)
        assistantModel = value
        return value
    }

    var calendar: CalendarModel {
        if let calendarModel { return calendarModel }
        let value = CalendarModel(app: self)
        calendarModel = value
        return value
    }

    func showCalendar() { destination = .calendar }

    func calendarAccounts() async throws -> [AccountRecord] {
        try await accounts?.accounts() ?? []
    }

    func calendarPreferences(accountID: String) async throws -> [CalendarPreferences] {
        try await accounts?.calendarPreferences(accountID: accountID) ?? []
    }

    func saveCalendarPreferences(_ preferences: CalendarPreferences) async throws {
        guard let accounts else { throw CalendarModelError.unavailable }
        try await accounts.saveCalendarPreferences(preferences)
    }

    func calendarService(for accountID: String) -> GoogleCalendarClient? {
        guard let session = sessions[accountID], session.isSignedIn,
              !accountsNeedingSignIn.contains(accountID) else { return nil }
        return GoogleCalendarClient(tokens: session)
    }

    func calendarStoreURL() throws -> URL {
        try Self.dataDirectory().appending(path: "calendar.sqlite")
    }
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
    @ObservationIgnored private var inboxWatchers: [String: InboxWatcher] = [:]
    @ObservationIgnored private var activityObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var isMacAsleep = false
    @ObservationIgnored private let activityGuard = SyncActivityGuard()
    /// What the user is doing, which sets how often each account checks for mail.
    private(set) var syncActivity: SyncActivity = .active
    @ObservationIgnored private var inboxUpdatesAreStopped = false
    @ObservationIgnored private var inboxReconciliationRevision = 0

    var settingsAccountStore: AccountStore? { accounts }

    func settingsClient(for accountID: String) -> GmailClient? {
        guard mailbox?.account(id: accountID) != nil,
              let session = sessions[accountID], session.isSignedIn,
              !accountsNeedingSignIn.contains(accountID) else { return nil }
        return GmailClient(tokens: session, gmailRequestBudget: session.gmailRequestBudget)
    }

    func inboxWatcher(for accountID: String) -> InboxWatcher? { inboxWatchers[accountID] }

    /// Read current configuration after each authorization or feature change.
    /// A mailbox's initial AccountRecord may predate that change.
    private func refreshInboxUpdates() async {
        guard let accounts, !inboxUpdatesAreStopped else { return }
        inboxReconciliationRevision += 1
        let revision = inboxReconciliationRevision
        let records: [AccountRecord]
        do { records = try await accounts.accounts() }
        catch { return }
        guard !inboxUpdatesAreStopped, revision == inboxReconciliationRevision else { return }
        let eligible = records.filter { account in
            account.enabledFeatures.contains(AccountFeature.inboxUpdates.rawValue)
                && GoogleScopes.isCovered(.inboxUpdates, by: account.grantedScopes)
                && sessions[account.id]?.isSignedIn == true
                && !accountsNeedingSignIn.contains(account.id)
                && mailbox?.account(id: account.id) != nil
                && mailbox?.account(id: account.id)?.syncEnabled == true
        }
        let ids = Set(eligible.map(\.id))
        for id in Array(inboxWatchers.keys) where !ids.contains(id) {
            await inboxWatchers.removeValue(forKey: id)?.stop()
        }
        for record in eligible {
            guard !inboxUpdatesAreStopped, revision == inboxReconciliationRevision else { return }
            guard inboxWatchers[record.id] == nil,
                  let session = sessions[record.id], session.isSignedIn,
                  !accountsNeedingSignIn.contains(record.id),
                  let owner = mailbox?.account(id: record.id) else { continue }
            let engine = owner.engine
            let watcher = InboxWatcher(monitor: InboxMonitor(address: record.email, tokens: session)) {
                await engine.requestSync(reason: .inboxSignal)
            }
            inboxWatchers[record.id] = watcher
            watcher.start()
        }
    }

    private func stopInboxUpdates() async {
        inboxReconciliationRevision += 1
        let watchers = Array(inboxWatchers.values)
        inboxWatchers = [:]
        for watcher in watchers { await watcher.stop() }
    }
    /// Copies of the files attached to drafts, kept until the draft is sent or discarded.
    private var outgoingDirectory: URL?
    @ObservationIgnored private var cacheDownloadDirectory = MailboxModel.defaultDownloadsDirectory
    /// Mailboxes still stopping, so data is deleted only after they finish.
    private var closing: Task<Void, Never>?
    /// The latest sign-out or end of a sign-in. They run one at a time, so a
    /// sign-in that finishes while its account signs out can't save it back
    /// half deleted.
    private var accountChange: Task<Void, Never>?

    func start() async {
        observeActivity()
        await changeAccounts { [self] in await restoreAccounts() }
    }

    private func restoreAccounts() async {
        guard phase == .loading else { return }
        do {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-audit") || ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar") {
                let cache = try MailCache.inMemory()
                let accounts = try AccountStore.inMemory()
                let account = AccountRecord(id: "ui-audit", email: "audit@example.invalid", displayName: "UI Audit", grantedScopes: [], addedAt: .now)
                // A second account with other mail under the same thread,
                // message and label IDs.
                let second = AccountRecord(id: "ui-audit-2", email: "second@example.invalid", displayName: "Second Audit", grantedScopes: [], addedAt: .now)
                try await accounts.save(account)
                try await accounts.save(second)
                self.cache = cache
                self.accounts = accounts
                await startMailPreferences(store: accounts, cache: cache)
                let auditDirectory = FileManager.default.temporaryDirectory.appending(path: "Tern-UIAudit-\(UUID().uuidString)", directoryHint: .isDirectory)
                let outgoing = auditDirectory.appending(path: "Outgoing", directoryHint: .isDirectory)
                cacheDownloadDirectory = auditDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
                self.outgoingDirectory = outgoing
                let mailbox = MailboxModel(
                    account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: outgoing,
                    downloadsDirectory: cacheDownloadDirectory, snoozeStore: accounts
                )
                self.mailbox = mailbox
                bindMailNotificationRoutes()
                configureMailRuntime(mailbox.defaultAccount)
                mailNotifications?.prepareAccount(account.id)
                if ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar") { destination = .calendar }
                phase = .signedIn(account)
                AccountProfileImages.shared.setAuditImage(SenderAccountLabel.auditImage, for: account.id)
                if ProcessInfo.processInfo.arguments.contains("--ui-audit-reauth") {
                    accountsNeedingSignIn.insert(second.id)
                }
                Task {
                    mailNotifications?.prepareAccount(second.id)
                    await mailbox.addAccount(second, gmail: AuditGmail(.second), onCreate: configureMailRuntime)
                    mailbox.selectedMailbox = .combined(SystemLabel.inbox)
                    schedulePreferenceReconciliation()
                    spotlight.start()
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
            if let cache { await startMailPreferences(store: accounts, cache: cache) }

            let stored = try await accounts.accounts()
            try await removeLeftovers(keeping: Set(stored.map(\.id)))
            for account in stored {
                let session = await AccountSession.restore(accountID: account.id)
                adopt(session ?? AccountSession(accountID: account.id))
            }
            let signedIn = try await correctGrants(of: stored, in: accounts)
            guard let first = signedIn.first else {
                phase = .signedOut
                return
            }
            for account in signedIn {
                if let session = sessions[account.id], session.isSignedIn {
                    AccountProfileImages.shared.refresh(accountID: account.id, tokens: session)
                }
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
        // The store, not the window's copy, has features turned on since the
        // window opened. The new grant has to cover them to keep them on.
        let stored = try? await accounts.accounts().first { $0.id == returning?.id }
        let user: GoogleAuth.SignedInUser
        do {
            user = try await auth.signIn(
                loginHint: returning?.email,
                features: GoogleScopes.featuresForSignIn(storedFeatures: stored?.enabledFeatures ?? returning?.enabledFeatures),
                isWorkspace: stored?.hostedDomain != nil
            )
        } catch is CancellationError {
            return
        } catch {
            reportSignInError(error.localizedDescription)
            return
        }
        await changeAccounts { [self] in await finishSignIn(as: user, returning: returning) }
    }

    private func finishSignIn(as user: GoogleAuth.SignedInUser, returning: AccountRecord?) async {
        guard let accounts else { return }
        do {
            if let returning, returning.id != user.id {
                // Replacing the account would delete its drafts and unsent
                // messages, so that takes Sign Out, which asks. The new
                // session is dropped unsaved, so nothing gets its tokens.
                reportSignInError("Signed in as \(user.email). Use \(returning.email) to keep its drafts and unsent mail, or sign out of that account first.")
                return
            }
            let stored = try await accounts.accounts().first { $0.id == user.id }
            if returning != nil, stored == nil {
                // Signed out while Google's page was open. The new session
                // is dropped unsaved.
                return
            }
            let session: AccountSession
            if let existing = sessions[user.id] {
                // Clients holding the session pick up the new tokens.
                try await existing.replace(with: user.state)
                guard sessions[user.id] === existing, existing.isSignedIn else { return }
                session = existing
            } else {
                session = AccountSession(accountID: user.id, state: user.state)
                try await session.save()
                adopt(session)
            }
            let (email, displayName, granted, hostedDomain) = (user.email, user.displayName, user.grantedScopes, user.hostedDomain)
            let account: AccountRecord
            if stored != nil, let updated = try await accounts.updateAccount(id: user.id, { account in
                // The account keeps when it was added and its settings.
                // Features the new grant doesn't cover turn off.
                account.email = email
                account.displayName = displayName
                account.grantedScopes = granted
                account.hostedDomain = hostedDomain
                account.enabledFeatures = AccountFeature.names(of: GoogleScopes.covered(account.enabledFeatures, by: granted))
            }) {
                account = updated
            } else {
                account = AccountRecord(
                    id: user.id, email: email, displayName: displayName, grantedScopes: granted,
                    addedAt: .now, hostedDomain: hostedDomain, enabledFeatures: AccountFeature.names(of: user.grant.features)
                )
                try await accounts.save(account)
            }
            AccountProfileImages.shared.refresh(accountID: account.id, tokens: session)
            accountsNeedingSignIn.remove(account.id)
            let turnedOff = AccountFeature.named(stored?.enabledFeatures ?? []).subtracting(AccountFeature.named(account.enabledFeatures))
            defer { if !turnedOff.isEmpty { reportTurnedOff(turnedOff, for: account) } }
            guard let mailbox else {
                await openMailbox(for: try await accounts.accounts())
                return
            }
            if let owner = mailbox.account(id: account.id) {
                // Back after the session ended: the open mailbox carries on.
                if case .signInRequired = phase { phase = .signedIn(mailbox.account) }
                owner.syncNow()
            } else {
                mailNotifications?.prepareAccount(account.id)
                let syncEnabled = (try? await accounts.mailPreferences(accountID: account.id).syncEnabled) ?? true
                await mailbox.addAccount(account, gmail: GmailClient(tokens: session, gmailRequestBudget: session.gmailRequestBudget), syncEnabled: syncEnabled, onCreate: configureMailRuntime)
                if case .signInRequired(let old) = phase {
                    // Added from Settings while the only account needed
                    // sign-in. With several, its section asks instead.
                    accountsNeedingSignIn.insert(old.id)
                    phase = .signedIn(mailbox.account)
                }
            }
            // A new grant may restore an expired token or remove IMAP access.
            await inboxWatchers.removeValue(forKey: account.id)?.stop()
            await refreshInboxUpdates()
            await accountPreferences?.refresh()
        } catch is CancellationError {
            return
        } catch {
            reportSignInError(error.localizedDescription)
        }
    }

    /// Runs `change` after the account changes already started.
    private func changeAccounts(_ change: @escaping @MainActor () async -> Void) async {
        _ = try? await changeAccounts(returning: change)
    }

    /// `changeAccounts(_:)` for a change with a result or an error.
    private func changeAccounts<Value: Sendable>(
        returning change: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let previous = accountChange
        let task = Task {
            await previous?.value
            return try await change()
        }
        accountChange = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Tells the window which features a sign-in turned off.
    private func reportTurnedOff(_ features: Set<AccountFeature>, for account: AccountRecord) {
        let names = ListFormatter.localizedString(
            byJoining: AccountFeature.allCases.filter(features.contains).map(\.displayName)
        )
        let message = features.count == 1
            ? "\(names) is off for \(account.email) because Google didn't grant the access it needs. Turn it on again in Settings."
            : "\(names) are off for \(account.email) because Google didn't grant the access they need. Turn them on again in Settings."
        mailbox?.notice = MailboxModel.Notice(message: message)
    }

    // MARK: Features

    /// Turns on `feature` for a signed-in account. Google's page asks for it
    /// together with the features already on, and the account's session
    /// switches to the new grant. Returns what the grant covers, which names
    /// any permission the user unticked. Nil when nothing changed: the user
    /// closed Google's page, another sign-in was running, or the account
    /// signed out or lost its session meanwhile.
    ///
    /// - Throws: `GoogleAuth.AuthError.otherAccount` or
    ///   `.gmailAccessNotGranted`, with the old session kept, and errors from
    ///   Google's page or storing the session.
    func enableFeature(_ feature: AccountFeature, for accountID: String) async throws -> FeatureGrant? {
        guard !isSigningIn, let accounts, let session = sessions[accountID], session.isSignedIn else { return nil }
        isSigningIn = true
        defer { isSigningIn = false }
        guard let stored = try await accounts.accounts().first(where: { $0.id == accountID }) else { return nil }
        // Several features use the same full-mail grant. Enabling another
        // covered feature changes local use without another consent screen.
        if let granted = session.grantedScopes, GoogleScopes.isCovered(feature, by: granted) {
            return try await changeAccounts(returning: { [self] in
                guard sessions[accountID] === session, session.isSignedIn else { return nil }
                guard let updated = try await accounts.updateAccount(id: accountID, { account in
                    account.enabledFeatures = AccountFeature.names(of:
                        AccountFeature.named(account.enabledFeatures).union([feature]))
                }) else { return nil }
                await refreshInboxUpdates()
                await calendarModel?.refresh()
                return try FeatureGrant(subject: accountID, granted: granted, accountID: accountID,
                    features: AccountFeature.named(updated.enabledFeatures))
            })
        }
        let user: GoogleAuth.SignedInUser
        do {
            user = try await auth.signIn(
                loginHint: accountID, accountID: accountID,
                features: AccountFeature.named(stored.enabledFeatures).union([feature]),
                isWorkspace: stored.hostedDomain != nil
            )
        } catch is CancellationError {
            return nil
        }
        return try await changeAccounts(returning: { [self] in
            // A sign-out, or a new sign-in that replaced the session, wins.
            guard sessions[accountID] === session, session.isSignedIn else { return nil }
            try await session.replace(with: user.state)
            guard sessions[accountID] === session, session.isSignedIn else { return nil }
            let (granted, hostedDomain) = (user.grantedScopes, user.hostedDomain)
            try await accounts.updateAccount(id: accountID) { account in
                // Features turned off while Google's page was open stay off.
                let wanted = AccountFeature.named(account.enabledFeatures).union([feature])
                account.grantedScopes = granted
                account.hostedDomain = hostedDomain
                account.enabledFeatures = AccountFeature.names(of: wanted.filter { GoogleScopes.isCovered($0, by: granted) })
            }
            await calendarModel?.refresh()
            await inboxWatchers.removeValue(forKey: accountID)?.stop()
            await refreshInboxUpdates()
            return user.grant
        })
    }

    /// Turns `feature` off and deletes what it kept. The grant keeps its
    /// scopes until the user removes Tern on their Google Account's
    /// permissions page.
    func disableFeature(_ feature: AccountFeature, for accountID: String) async throws {
        try await changeAccounts(returning: { [self] in
            guard let accounts, let cache else { return }
            try await accounts.updateAccount(id: accountID) { account in
                account.enabledFeatures.removeAll { $0 == feature.rawValue }
            }
            if feature == .contacts {
                try await cache.write { tx in try tx.deleteContacts(accountID: accountID) }
            }
            await refreshInboxUpdates()
            if feature == .calendar {
                await calendarModel?.removeAccount(accountID)
            } else if feature == .calendarManagement || feature == .calendarSharing {
                await calendarModel?.refresh()
            }
        })
    }

    /// Corrects each record from its account's stored authorization: an
    /// account added before Tern kept `hd`, or one whose Keychain item was
    /// written but not its record.
    private func correctGrants(of records: [AccountRecord], in accounts: AccountStore) async throws -> [AccountRecord] {
        var corrected: [AccountRecord] = []
        for record in records {
            guard let session = sessions[record.id], let granted = session.grantedScopes else {
                corrected.append(record)
                continue
            }
            // The last token response may carry no ID token, which leaves
            // the stored domain as it was.
            let hostedDomain = session.idTokenHostedDomain ?? record.hostedDomain
            let features = AccountFeature.names(of: GoogleScopes.covered(record.enabledFeatures, by: granted))
            guard Set(granted) != Set(record.grantedScopes) || hostedDomain != record.hostedDomain
                    || features != record.enabledFeatures
            else {
                corrected.append(record)
                continue
            }
            let updated = try await accounts.updateAccount(id: record.id) { account in
                account.grantedScopes = granted
                account.hostedDomain = hostedDomain
                account.enabledFeatures = features
            }
            corrected.append(updated ?? record)
        }
        return corrected
    }

    /// Settings and sign-in show the error; an open mailbox also gets a notice.
    private func reportSignInError(_ message: String) {
        signInError = message
        if case .signedIn = phase, let mailbox {
            mailbox.notice = MailboxModel.Notice(message: message, isError: true)
        }
    }

    /// Signs out of every account.
    func signOut() async {
        await changeAccounts { [self] in await signOutOfEveryAccount() }
    }

    private func signOutOfEveryAccount() async {
        guard let accounts else { return }
        signInError = nil
        for owner in mailbox?.accounts ?? [] {
            assistantModel?.setAccountEnabled(owner.account.id, enabled: false)
        }
        AccountProfileImages.shared.removeAll()
        await closeMailbox()
        spotlight.removeAll()
        let signedOut = sessions
        sessions = [:]
        accountsNeedingSignIn = []
        do {
            for account in try await accounts.accounts() {
                try await removeAccountData(account, session: signedOut[account.id], from: accounts)
            }
            // Only signed-in accounts keep downloaded attachments and the
            // files attached to their drafts.
            try? FileManager.default.removeItem(at: cacheDownloadDirectory)
            if let outgoingDirectory { try? FileManager.default.removeItem(at: outgoingDirectory) }
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Signs out of one account while the others stay. The last account
    /// signs out of Tern.
    func signOut(of accountID: String) async {
        await changeAccounts { [self] in await signOutOfOne(accountID) }
    }

    private func signOutOfOne(_ accountID: String) async {
        guard let mailbox, mailbox.hasSeveralAccounts, let accounts, let owner = mailbox.account(id: accountID) else {
            // The last account signs out of Tern. One that an earlier change
            // already signed out needs nothing more.
            if mailbox == nil || mailbox?.account(id: accountID) != nil { await signOutOfEveryAccount() }
            return
        }
        let account = owner.account
        signInError = nil
        assistantModel?.setAccountEnabled(accountID, enabled: false)
        AccountProfileImages.shared.remove(accountID: accountID)
        await mailNotifications?.removeAccount(accountID)
        await inboxWatchers.removeValue(forKey: accountID)?.stop()
        await mailbox.removeAccount(id: accountID)
        let session = sessions.removeValue(forKey: accountID)
        accountsNeedingSignIn.remove(accountID)
        phase = .signedIn(mailbox.account)
        if !mailbox.hasSeveralAccounts, accountsNeedingSignIn.remove(mailbox.account.id) != nil {
            // The account left needs sign-in, which one account shows in the window.
            phase = .signInRequired(mailbox.account)
        }
        do {
            try await removeAccountData(account, session: session, from: accounts)
        } catch {
            // Once its record is gone, the next launch deletes what's left.
            mailbox.notice = MailboxModel.Notice(message: "Couldn't remove all local data for \(account.email).", isError: true)
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
        let deletes = "Downloaded mail and pending changes will be deleted from this Mac"
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
        session.onSignInRequired = { [weak self, weak session] in
            guard let self, let session, sessions[accountID] === session else { return }
            sessionExpired(accountID)
        }
        sessions[accountID] = session
    }

    /// Saves, sends and label changes retry until the user signs in again.
    /// With several accounts only this one's section asks for sign-in.
    private func sessionExpired(_ accountID: String) {
        guard let mailbox, mailbox.account(id: accountID) != nil else { return }
        inboxReconciliationRevision += 1
        let watcher = inboxWatchers.removeValue(forKey: accountID)
        Task { [weak self] in
            await watcher?.stop()
            await self?.refreshInboxUpdates()
        }
        if mailbox.hasSeveralAccounts {
            accountsNeedingSignIn.insert(accountID)
        } else if case .signedIn(let account) = phase {
            phase = .signInRequired(account)
        }
        assistantModel?.refreshAccess()
        calendarModel?.accessExpired(accountID)
    }

    // MARK: Quitting

    /// What stops a quit until the person tries again, stays open or quits anyway.
    enum QuitProblem: Error, Equatable {
        /// Open drafts Tern couldn't store, by window title.
        case unsavedDrafts([String])
        /// The Outbox couldn't be read, so what still waits to send is unknown.
        case unreadableOutbox
    }

    /// Stores what open compose windows show, so quitting loses no typing.
    /// Nothing has stopped when this throws, so Tern can stay open as it was.
    func storeOpenDrafts() async throws(QuitProblem) {
        let unsaved = await mailbox?.prepareToQuit() ?? []
        guard unsaved.isEmpty else { throw QuitProblem.unsavedDrafts(unsaved) }
    }

    /// Stops background work before quitting. `cancelQuit()` starts it again.
    func prepareToQuit() async {
        inboxUpdatesAreStopped = true
        await maintenanceModel?.suspend()
        maintenanceTask?.cancel()
        maintenanceTask = nil
        mailURLRouter?.stop()
        await stopInboxUpdates()
        assistantModel?.stop()
        assistantModel?.connection.cancelSignIn()
        await calendarModel?.stop()
    }

    /// A user can keep Tern open after its final send attempt fails.
    func cancelQuit() async {
        inboxUpdatesAreStopped = false
        maintenanceModel?.resume()
        await refreshInboxUpdates()
        await calendarModel?.start()
        assistantModel?.refreshAccess()
        schedulePreferenceReconciliation()
        mailURLRouter?.resume()
        startCacheMaintenance()
    }

    /// Drafts whose send waits out its undo delay or a retry, which quitting
    /// sends at once. Read from the cache, since the Outbox can lag behind a
    /// send that just changed. A read that fails throws rather than passing
    /// for an empty Outbox.
    func sendingDraftIDs() async throws(QuitProblem) -> Set<String> {
        let paused = Set(mailbox?.accounts.filter { !$0.syncEnabled }.map(\.account.id) ?? [])
        let drafts = try await localDrafts()
        return Set(drafts.filter { $0.state == .sending && !paused.contains($0.accountID) }.map(\.id))
    }

    /// How many of `ids` Gmail refused to send, which returns them to editing.
    func refusedDraftCount(among ids: Set<String>) async throws(QuitProblem) -> Int {
        let drafts = try await localDrafts()
        return drafts.filter { ids.contains($0.id) && $0.state == .editing }.count
    }

    private func localDrafts() async throws(QuitProblem) -> [LocalDraft] {
        guard let cache, let accountIDs = mailbox?.accounts.map(\.account.id) else { return [] }
        return try await Self.localDrafts(of: accountIDs, in: cache)
    }

    /// The drafts of `accountIDs` in `cache`. A read that fails throws, so it
    /// never passes for an Outbox with nothing waiting.
    static func localDrafts(of accountIDs: [String], in cache: MailCache) async throws(QuitProblem) -> [LocalDraft] {
        do {
            return try await cache.read { tx in try accountIDs.flatMap { try tx.localDrafts(accountID: $0) } }
        } catch {
            throw QuitProblem.unreadableOutbox
        }
    }

    /// Sends every waiting message now. False when one of them couldn't
    /// reach Gmail or Gmail refused it, or `timeout` passed first. A send still
    /// running after the timeout keeps going, and the next launch finishes one
    /// cut off by quitting.
    func sendWaitingMessages(timeout: Duration = .seconds(10)) async -> Bool {
        guard let engines = mailbox?.accounts.filter(\.syncEnabled).map(\.engine), !engines.isEmpty else { return true }
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
    private func mailboxService(for accountID: String) -> (any GmailService)? {
        if let session = sessions[accountID] { return GmailClient(tokens: session, gmailRequestBudget: session.gmailRequestBudget) }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
            return accountID == "ui-audit-2" ? AuditGmail(.second) : AuditGmail()
        }
#endif
        return nil
    }

    private func openMailbox(for records: [AccountRecord]) async {
        guard let cache, let accounts, let outgoingDirectory,
              let first = records.first, let gmail = mailboxService(for: first.id)
        else { return }
        await closeMailbox()
        let mailbox = MailboxModel(
            account: first, cache: cache, gmail: gmail,
            outgoingDirectory: outgoingDirectory, downloadsDirectory: cacheDownloadDirectory, snoozeStore: accounts,
            syncEnabled: (try? await accounts.mailPreferences(accountID: first.id).syncEnabled) ?? true
        )
        configureMailRuntime(mailbox.defaultAccount)
        mailNotifications?.prepareAccount(first.id)
        for record in records.dropFirst() {
            guard let gmail = mailboxService(for: record.id) else { continue }
            mailNotifications?.prepareAccount(record.id)
            let syncEnabled = (try? await accounts.mailPreferences(accountID: record.id).syncEnabled) ?? true
            await mailbox.addAccount(record, gmail: gmail, syncEnabled: syncEnabled, onCreate: configureMailRuntime)
        }
        if mailbox.hasSeveralAccounts { mailbox.selectedMailbox = .combined(SystemLabel.inbox) }
        self.mailbox = mailbox
        bindMailNotificationRoutes()
        phase = .signedIn(first)
        if records.count == 1, let session = sessions[first.id], !session.isSignedIn { phase = .signInRequired(first) }
        schedulePreferenceReconciliation()
        mailURLRouter?.resume()
        await refreshInboxUpdates()
        startCacheMaintenance()
        spotlight.start()
        Task { await mailbox.start() }
    }

    /// Stops the open mailbox and waits for every mailbox still stopping.
    private func closeMailbox() async {
        MailNotificationRouter.shared.unbind()
        mailURLRouter?.stop()
        await stopInboxUpdates()
        assistantNavigationTask?.cancel()
        assistantModel?.newChat()
        if let mailbox {
            self.mailbox = nil
            let previous = closing
            closing = Task {
                await previous?.value
                await mailbox.stop()
            }
        }
        await closing?.value
        refreshMailBadges()
    }

    /// Deletes an account's record, snoozes, Keychain item, cache rows and
    /// files. The record goes first, so if this stops partway the next
    /// launch deletes the rest instead of asking to sign in again.
    private func removeAccountData(
        _ account: AccountRecord, session: AccountSession?, from accounts: AccountStore
    ) async throws {
        assistantModel?.forgetAccount(account.id)
        await mailNotifications?.removeAccount(account.id)
        try await accounts.deleteAccount(id: account.id)
        await calendarModel?.removeAccount(account.id)
        await session?.signOut()
        // A session that failed to restore at launch can leave its item behind.
        try? await KeychainStore.delete(account: account.id)
        do { try AssistantWritingStyleCleanup.remove(accountID: account.id) }
        catch { reportSignInError("Some saved writing-style data could not be deleted.") }
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
        spotlight.remove(accountIDs: accountIDs)
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
                at: cacheDownloadDirectory.appending(path: accountID, directoryHint: .isDirectory)
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

extension AccountFeature {
    /// The feature's name in Settings.
    var displayName: String {
        switch self {
        case .gmailSettings: "Gmail Settings"
        case .contacts: "Contacts"
        case .inboxUpdates: "Inbox Updates"
        case .permanentDeletion: "Permanent Deletion"
        case .calendar: "Google Calendar"
        case .calendarManagement: "Calendar Management"
        case .calendarSharing: "Calendar Sharing"
        }
    }
}
