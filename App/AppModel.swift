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
    /// How this process was launched, which decides whether the model opens
    /// the user's data or synthetic data.
    let launchMode: LaunchMode
    let onboarding = OnboardingState.appState()
    private(set) var isSigningIn = false
    private(set) var signInError: String?
    /// The open mailbox. It stays open while the session has expired, so
    /// compose windows keep working and queued changes wait for sign-in.
    private(set) var mailbox: MailboxModel?
    @ObservationIgnored private var assistantModel: AssistantModel?
    @ObservationIgnored private var organizationSessionsModel: MailOrganizationSessions?
    @ObservationIgnored private var calendarModel: CalendarModel?
    @ObservationIgnored private var tasksModel: GoogleTasksModel?
    @ObservationIgnored private var followUpsModel: FollowUpsModel?
    @ObservationIgnored private var todayModel: TodayModel?
    @ObservationIgnored private var todayDashboardModel: TodayDashboardModel?
    @ObservationIgnored private var automaticFollowUpsModel: AutomaticFollowUpCoordinator?
    var meetingPreparation: MeetingPreparationModel?
    /// Isolated launches keep follow-up preferences in memory, away from the user's defaults.
    let followUpPreferences: FollowUpPreferences
    /// A task created from a detached reader can reveal the main window's sidebar.
    private(set) var tasksSidebarRequest: UUID?
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
    var destination: WorkspaceDestination = .mail {
        didSet {
            guard destination != oldValue else { return }
            if destination != .today {
                todayModel?.endVisit()
                todayDashboardModel?.stop()
            }
            NavigationPerformance.shared.begin(.workspace, destination: destination.rawValue)
            if destination != .mail {
                NavigationPerformance.shared.cancel(.reader)
                NavigationPerformance.shared.cancel(.mailbox)
            }
        }
    }
    @ObservationIgnored var assistantNavigationTask: Task<Void, Never>?
    /// Set by the main window's root view. The Dock, notifications and a
    /// Dock-icon click with no window open use it to show the window again.
    @ObservationIgnored var openMainWindow: (@MainActor () -> Void)? {
        didSet { CalendarNotificationRouter.shared.openMainWindow = openMainWindow }
    }

    init(launchMode: LaunchMode = .current) {
        self.launchMode = launchMode
        followUpPreferences = FollowUpPreferences(defaults: launchMode.isIsolated ? nil : .standard)
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
        let isolated = launchMode.isIsolated
        let defaults = isolated
            ? UserDefaults(suiteName: "tern.audit.spotlight.\(UUID().uuidString)") ?? UserDefaults()
            : .standard
        let removal = isolated ? MailSpotlightRemoval(defaults: defaults, remove: { _ in }) : nil
        let indexer = MailSpotlightIndexer(app: self, defaults: defaults,
                                         removal: removal, allowsIndexing: !isolated)
        spotlightIndexer = indexer
        return indexer
    }

    var spotlightRemoval: MailSpotlightRemoval { spotlight.removal }
    func retrySpotlightRemoval() { spotlight.retryRemoval() }

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
        guard maintenanceTask == nil, !launchMode.isIsolated else { return }
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
        ReaderCacheLifecycle.reset()
        ContactThumbnailCache.shared.removeAll()
        isResettingCache = true
        meetingPreparation?.stop()
        meetingPreparation = nil
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
            ReaderCacheLifecycle.reset()
            ContactThumbnailCache.shared.removeAll()
            AttachmentPresentation.removeAll()
            await EmailCalendarPreparation.shared.removeAll()
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
        if launchMode.isIsolated {
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
        MailNotificationRouter.shared.bindFollowUps { [weak self] target in
            guard let self, mailbox?.account(id: target.accountID) != nil else { return }
            showMainWindow()
            if let preferences = accountPreferences, !preferences.visibleAccountIDs.contains(target.accountID) {
                preferences.selectProfile(nil)
            }
            destination = .followUps
            await followUps.openNotification(accountID: target.accountID, commitmentID: target.commitmentID)
        }
    }

    /// A conversation window has it open, or the mailbox shows it selected.
    private func isConversationOnScreen(_ key: ThreadKey) -> Bool {
        if visibleConversationKeys.contains(key) { return true }
        guard destination == .mail, let mailbox else { return false }
        return mailbox.selectedThreadIDs.contains(key)
    }

    /// The mailbox Spotlight was last asked to rebuild its index from.
    @ObservationIgnored private weak var spotlightMailbox: MailboxModel?

    /// Rebuilds the Spotlight index from `mailbox`. Syncs keep it current
    /// from here on.
    private func startSpotlight(for mailbox: MailboxModel) {
        spotlightMailbox = mailbox
        spotlight.start()
    }

    /// Indexes what a sync changed. A pass that left the history cursor
    /// where it was brought no records, so the conversations Spotlight
    /// listed last still stand and aren't read again. A sync that lands
    /// before the rebuild is asked for is covered by the rebuild.
    private func indexInSpotlight(after snapshot: MailSyncNotification) {
        guard let mailbox, spotlightMailbox === mailbox,
              snapshot.fromHistoryID != snapshot.toHistoryID else { return }
        spotlight.mailSynced(accountID: snapshot.accountID)
    }

    private func configureMailRuntime(_ owner: AccountMailbox) {
        owner.onMailSync = { [weak self] snapshot in
            self?.indexInSpotlight(after: snapshot)
            await self?.meetingPreparation?.process(snapshot)
            await self?.mailNotifications?.process(snapshot)
            await self?.automaticFollowUpsModel?.process(snapshot)
            await self?.followUpsModel?.process(snapshot)
            await self?.todayDashboardModel?.process(snapshot)
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
        syncActivityGeneration += 1
        let generation = syncActivityGeneration
        let expectedMailbox = mailbox
        if activity != .active {
            todayModel?.endVisit()
            todayDashboardModel?.stop()
        }
        for owner in mailbox?.accounts ?? [] { owner.setActivity(activity) }
        if activity == .suspended {
            meetingPreparation?.cancel()
            automaticFollowUpsModel?.stop()
            followUpsModel?.stop()
        } else if let followUpsModel, !inboxUpdatesAreStopped {
            // Today's panels refresh at once; the follow-up resume below can take seconds.
            Task {
                guard self.canResumeFollowUps(in: expectedMailbox, generation: generation),
                      self.syncActivity == .active, self.destination == .today else { return }
                await self.todayDashboardModel?.refresh()
            }
            Task {
                guard self.canResumeFollowUps(in: expectedMailbox, generation: generation) else { return }
                await self.automaticFollowUpsModel?.start()
                guard self.canResumeFollowUps(in: expectedMailbox, generation: generation) else { return }
                await followUpsModel.resume()
                guard self.canResumeFollowUps(in: expectedMailbox, generation: generation) else { return }
                if self.syncActivity == .active, self.destination == .today {
                    await self.todayModel?.beginVisit()
                }
            }
        }
    }

    private func canResumeFollowUps(in expectedMailbox: MailboxModel?, generation: Int) -> Bool {
        guard let expectedMailbox else { return false }
        return generation == syncActivityGeneration && !inboxUpdatesAreStopped
            && syncActivity != .suspended && mailbox === expectedMailbox
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
            let generation = syncActivityGeneration
            if canResumeFollowUps(in: mailbox, generation: generation) {
                await automaticFollowUpsModel?.start()
                if canResumeFollowUps(in: mailbox, generation: generation) { await followUpsModel?.refresh() }
            }
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

    var organizationSessions: MailOrganizationSessions {
        if let organizationSessionsModel { return organizationSessionsModel }
        let value = MailOrganizationSessions(app: self)
        organizationSessionsModel = value
        return value
    }

    var calendar: CalendarModel {
        if let calendarModel { return calendarModel }
        let value = CalendarModel(app: self)
        calendarModel = value
        return value
    }

    var tasks: GoogleTasksModel {
        if let tasksModel { return tasksModel }
        let value = GoogleTasksModel(app: self)
        tasksModel = value
        return value
    }

    var followUps: FollowUpsModel {
        if let followUpsModel { return followUpsModel }
        let value = FollowUpsModel(app: self)
        followUpsModel = value
        return value
    }

    var today: TodayModel {
        if let todayModel { return todayModel }
        let value = TodayModel(app: self)
        todayModel = value
        return value
    }

    var todayDashboard: TodayDashboardModel {
        if let todayDashboardModel { return todayDashboardModel }
        let value = TodayDashboardModel(app: self)
        todayDashboardModel = value
        return value
    }

    var automaticFollowUps: AutomaticFollowUpCoordinator {
        if let automaticFollowUpsModel { return automaticFollowUpsModel }
        let value = AutomaticFollowUpCoordinator(app: self, preferences: followUpPreferences, followUps: followUps)
        automaticFollowUpsModel = value
        followUpPreferences.onChange = { [weak self] in
            Task { await self?.automaticFollowUpsModel?.preferencesChanged() }
        }
        return value
    }

    func showTasks() {
        showMainWindow()
        tasksSidebarRequest = UUID()
    }

    func didShowTasks() { tasksSidebarRequest = nil }

    func tasksAccounts() async throws -> [AccountRecord] {
        try await accounts?.accounts() ?? []
    }

    func tasksService(for accountID: String) -> GoogleTasksClient? {
        guard let session = sessions[accountID], session.isSignedIn,
              !accountsNeedingSignIn.contains(accountID),
              let scopes = session.grantedScopes, GoogleScopes.isCovered(.tasks, by: scopes) else { return nil }
        return GoogleTasksClient(tokens: session)
    }

    func enableTasks(for accountID: String) async throws {
        let needsSignIn = sessions[accountID]?.isSignedIn != true || accountsNeedingSignIn.contains(accountID)
        if needsSignIn {
            await signInAgain(to: accountID)
            guard sessions[accountID]?.isSignedIn == true, !accountsNeedingSignIn.contains(accountID) else {
                throw CancellationError()
            }
        }
        let rejectedGrant = !needsSignIn && tasksModel?.selectedAccountID == accountID && tasksModel?.issue?.needsConnection == true
        guard let grant = try await enableFeature(.tasks, for: accountID, forceConsent: rejectedGrant) else { throw CancellationError() }
        guard grant.features.contains(.tasks) else { throw GoogleTasksModelError.unavailable }
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
    /// Accounts needing renewed Google access. Their cached mail stays open.
    private(set) var accountsNeedingSignIn: Set<String> = []
    /// Sign Out of every account, waiting for confirmation.
    var isConfirmingSignOut = false
    /// Sign Out of one of several accounts, waiting for confirmation.
    var accountToSignOut: AccountRecord?

    let auth = GoogleAuth(configuration: .fromBundle())
    private(set) var cache: MailCache?
    private var accounts: AccountStore?
    @ObservationIgnored private var accountCleanup: AccountCleanupCoordinator?
    /// Each signed-in account's tokens, by account ID.
    private var sessions: [String: AccountSession] = [:]
    @ObservationIgnored private var inboxWatchers: [String: InboxWatcher] = [:]
    @ObservationIgnored private var activityObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var isMacAsleep = false
    @ObservationIgnored private let activityGuard = SyncActivityGuard()
    /// What the user is doing, which sets how often each account checks for mail.
    private(set) var syncActivity: SyncActivity = .active
    @ObservationIgnored private var syncActivityGeneration = 0
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
            guard !inboxUpdatesAreStopped, revision == inboxReconciliationRevision else { return }
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
        for watcher in detachInboxWatchers() { await watcher.stop() }
    }

    /// Takes every watcher out of service and hands them to the caller to stop.
    private func detachInboxWatchers() -> [InboxWatcher] {
        inboxReconciliationRevision += 1
        let watchers = Array(inboxWatchers.values)
        inboxWatchers = [:]
        return watchers
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
        // Read off the main actor now, so the assistant's first use finds the saved styles in memory.
        AssistantWritingStyleStores.preload()
        observeActivity()
        spotlight.retryRemoval()
        // Shared .eml files hold whole messages, and an earlier run may have left some.
        await TemporaryShareFile.removeAll()
        await changeAccounts { [self] in await restoreAccounts() }
    }

    /// Why the stores didn't open, the accounts didn't restore or signing
    /// out stopped, which sets what the failure screen offers.
    enum LaunchFailure: Equatable {
        /// The disk is full. Once there's space, Try Again opens the mail as it was.
        case diskFull
        /// The mail cache didn't open, so a new one can take its place.
        case cache(damaged: Bool)
        /// Another copy of Tern or another app has the mail locked. Try Again
        /// opens it as it was once that ends, so it isn't offered a new cache.
        case inUse
        /// Signing out of every account stopped partway. Try Again signs out
        /// of the accounts that are left and never restores them.
        case signOut
        case other
    }

    /// Set with `.failed` by a launch or a sign-out that failed.
    private(set) var launchFailure: LaunchFailure?
    /// A new mail cache is being started in place of one that won't open.
    private(set) var isRecoveringCache = false
    /// What the new mail cache kept, until the alert reporting it closes.
    var cacheRecovery: CacheRecovery?
    /// Why a new mail cache couldn't be started, until the alert closes.
    var cacheRecoveryError: String?

    /// An error from opening the mail cache rather than the account store.
    private struct CacheOpenFailure: Error {
        let error: any Error
    }

    private func restoreAccounts() async {
        guard phase == .loading else { return }
        launchFailure = nil
        do {
#if TERN_TEST_SUPPORT || TERN_PERFORMANCE
            if launchMode.isIsolated {
                let cache = try MailCache.inMemory()
                let accounts = try AccountStore.inMemory()
                let audit = launchMode.audit
                let onboardingAudit = audit.onboarding != nil
                let emptyOnboarding = audit.onboarding == .empty
                let cachedReauthentication = audit.cachedReauth
                onboarding.resolve(hasExistingAccounts: !onboardingAudit)
                if onboardingAudit {
                    onboarding.step = audit.onboardingStep ?? (emptyOnboarding ? .welcome : .google)
                }
                let readmeDemo = ReadmeDemoFixtures.isEnabled
                let account = AccountRecord(id: "ui-audit",
                    email: readmeDemo ? "alex@studio.example.invalid" : "audit@example.invalid",
                    displayName: readmeDemo ? "Northstar Studio" : "UI Audit", grantedScopes: [], addedAt: .now)
                // A second account with other mail under the same thread,
                // message and label IDs.
                let second = AccountRecord(id: "ui-audit-2",
                    email: readmeDemo ? "alex@example.invalid" : "second@example.invalid",
                    displayName: readmeDemo ? "Personal" : "Second Audit", grantedScopes: [], addedAt: .now)
                if !emptyOnboarding {
                    try await accounts.save(account)
                    if !cachedReauthentication { try await accounts.save(second) }
                }
                self.cache = cache
                self.accounts = accounts
                await startMailPreferences(store: accounts, cache: cache)
                let auditDirectory = FileManager.default.temporaryDirectory.appending(path: "Tern-UIAudit-\(UUID().uuidString)", directoryHint: .isDirectory)
                let outgoing = auditDirectory.appending(path: "Outgoing", directoryHint: .isDirectory)
                cacheDownloadDirectory = auditDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
                self.outgoingDirectory = outgoing
                if emptyOnboarding {
                    phase = .signedOut
                    return
                }
                let mailbox = MailboxModel(
                    account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: outgoing,
                    downloadsDirectory: cacheDownloadDirectory, snoozeStore: accounts
                )
                self.mailbox = mailbox
                bindMailNotificationRoutes()
                configureMailRuntime(mailbox.defaultAccount)
                mailNotifications?.prepareAccount(account.id)
                if audit.calendar { destination = .calendar }
                phase = .signedIn(account)
                AccountProfileImages.shared.setAuditImage(SenderAccountLabel.auditImage, for: account.id)
                if audit.reauth {
                    accountsNeedingSignIn.insert(second.id)
                }
                Task {
                    if !cachedReauthentication {
                        mailNotifications?.prepareAccount(second.id)
                        await mailbox.addAccount(second, gmail: AuditGmail(.second), onCreate: configureMailRuntime)
                        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
                    }
                    schedulePreferenceReconciliation()
                    spotlight.start()
                    await mailbox.start()
                    if cachedReauthentication { sessionExpired(account.id) }
                    await PerformanceAudit.runIfRequested(app: self)
                }
                return
            }
#endif
            let directory = try Self.dataDirectory()
            let cacheURL = directory.appending(path: "cache.sqlite")
            // Try Again keeps the stores an earlier attempt opened.
            let (openAccounts, openCache) = (self.accounts, cache)
            if openCache == nil {
                // A Start New Mail Cache that Tern quit partway through
                // finishes first, so its alert shows even when the open fails.
                let resumed = try await Task.detached(priority: .userInitiated) {
                    do {
                        return try MailCache.finishRecovery(at: cacheURL)
                    } catch {
                        throw CacheOpenFailure(error: error)
                    }
                }.value
                if let resumed { cacheRecovery = resumed }
            }
            // Both stores can migrate on first launch after an update. Keep
            // SQLite setup off the main actor so the launch UI stays responsive.
            // The window stays hidden until it knows whether to show setup or
            // the mailbox. The accounts decide that and live in the small
            // config store, so it opens first and the window can show
            // "Opening your mail…" while the mail cache opens and migrates.
            let accounts = try await Task.detached(priority: .userInitiated) {
                try openAccounts ?? AccountStore.open(at: directory.appending(path: "config.sqlite"))
            }.value
            // An account whose sign-out stopped partway isn't opened again.
            // Its removal finishes below, after the mailbox opens.
            let removing = Set(try await accounts.pendingAccountRemovals().map(\.accountID))
            let stored = try await accounts.accounts().filter { !removing.contains($0.id) }
            onboarding.resolve(hasExistingAccounts: !stored.isEmpty)
            // The Keychain reads only need the account IDs, so they run while
            // the mail cache opens. Nothing uses a session before the await below.
            async let savedSessions = AccountSession.restore(accountIDs: stored.map(\.id))
            let openedCache = try await Task.detached(priority: .userInitiated) {
                do {
                    return try openCache ?? MailCache.open(at: cacheURL)
                } catch {
                    throw CacheOpenFailure(error: error)
                }
            }.value
            cache = openedCache
            outgoingDirectory = directory.appending(path: "Outgoing", directoryHint: .isDirectory)
            self.accounts = accounts
            await startMailPreferences(store: accounts, cache: openedCache)

            let restored = await savedSessions
            for account in stored {
                adopt(restored[account.id] ?? AccountSession(accountID: account.id))
            }
            let signedIn = try await correctGrants(of: stored, in: accounts)
            let kept = Set(stored.map(\.id))
            guard !signedIn.isEmpty else {
                // No cached mail waits on the cleanup here, so it keeps its
                // place before the sign-in screen.
                try await finishInterruptedRemovals(keeping: kept)
                phase = .signedOut
                return
            }
            for account in signedIn {
                if let session = sessions[account.id], session.isSignedIn {
                    AccountProfileImages.shared.refresh(accountID: account.id, tokens: session)
                }
            }
            let expired = signedIn.filter { sessions[$0.id]?.isSignedIn != true }
            accountsNeedingSignIn = Set(expired.map(\.id))
            await openMailbox(for: signedIn)
            if let signInError { reportSignInError(signInError) }
            // The cleanup reads every cache table and may wait on the
            // Keychain, and cached mail needs neither. It runs once the
            // mailbox is open, inside this same account change. A cleanup
            // that fails still fails the launch, with the mailbox closed.
            do {
                try await finishInterruptedRemovals(keeping: kept)
            } catch {
                await closeMailbox()
                throw error
            }
        } catch {
            let cacheError = (error as? CacheOpenFailure)?.error
            let failure = cacheError ?? error
            launchFailure = switch CacheOpenProblem(failure) {
            case .diskFull: .diskFull
            case .inUse: .inUse
            case let problem where cacheError != nil: .cache(damaged: problem == .damaged)
            default: .other
            }
            phase = .failed(failure.localizedDescription)
        }
    }

    /// Try Again on the launch failure screen: opens the stores again
    /// without a relaunch, or finishes a sign-out that stopped.
    func retryLaunch() async {
        if launchFailure == .signOut, case .failed = phase {
            await signOut()
            return
        }
        await changeAccounts { [self] in
            guard launchFailure != nil, case .failed = phase else { return }
            phase = .loading
            await restoreAccounts()
        }
    }

    /// Start New Mail Cache on the launch failure screen. The cache that
    /// won't open moves into a folder named for `date`, a new one starts with
    /// the unsent work that could be read from it, and the mail opens.
    func startNewMailCache(settingAsideAt date: Date) async {
        guard !isRecoveringCache else { return }
        isRecoveringCache = true
        defer { isRecoveringCache = false }
        await changeAccounts { [self] in
            // Nothing may have the old cache open while it moves.
            guard case .cache = launchFailure, case .failed = phase, cache == nil else { return }
            do {
                let url = try Self.dataDirectory().appending(path: "cache.sqlite")
                cacheRecovery = try await Task.detached(priority: .userInitiated) {
                    try MailCache.recover(at: url, setAsideAt: date)
                }.value
            } catch {
                cacheRecoveryError = error.localizedDescription
                return
            }
            phase = .loading
            await restoreAccounts()
        }
    }

    /// Sign-in from a screen that has no open cached workspace.
    func signIn() async {
        let returning: AccountRecord? = if case .signInRequired(let old) = phase { old } else { nil }
        await signIn(as: returning)
    }

    /// Renew access for any account without closing its cached workspace.
    func signInAgain(to accountID: String) async {
        guard let owner = mailbox?.account(id: accountID) else { return }
        await signIn(as: owner.account)
    }

    /// Adds another Google account to the window. Signing in to one that's
    /// already added refreshes its session only when the new grant keeps
    /// everything it has turned on (`addAccountReplacesSession`).
    func addAccount() async {
        await signIn(as: nil)
    }

    /// Whether Add Account may replace the session of `stored`, an account
    /// Tern already has, with a grant of `granted`. Add Account asks only for
    /// what a new account gets, so its grant can be narrower than the one
    /// the account has. It has to cover every feature the account has turned
    /// on, and the directory when the account searches it.
    static func addAccountReplacesSession(of stored: AccountRecord, granted: [String]) -> Bool {
        let features = AccountFeature.named(stored.enabledFeatures)
        guard features.allSatisfy({ GoogleScopes.isCovered($0, by: granted) }) else { return false }
        // Contacts works without the directory, which only a Workspace sign-in asks for.
        let searchesDirectory = features.contains(.contacts)
            && GoogleScopes.isCovered(GoogleScopes.directory, by: stored.grantedScopes)
        return !searchesDirectory || GoogleScopes.isCovered(GoogleScopes.directory, by: granted)
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
            try await cleanupCoordinator().prepareForSignIn(accountID: user.id)
            let stored = try await accounts.accounts().first { $0.id == user.id }
            if returning != nil, stored == nil {
                // Signed out while Google's page was open. The new session
                // is dropped unsaved.
                return
            }
            if returning == nil, let stored, !Self.addAccountReplacesSession(of: stored, granted: user.grantedScopes) {
                // Add Account on an account Tern has. Its session stays, and
                // the new one is dropped unsaved.
                let needsSignIn = accountsNeedingSignIn.contains(stored.id) || sessions[stored.id]?.isSignedIn != true
                reportSignInError("\(stored.email) is already added."
                    + (needsSignIn ? " To renew its access, click Sign In Again." : ""))
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
            if turnedOff.contains(.contacts) { ContactThumbnailCache.shared.remove(accountID: account.id) }
            if turnedOff.contains(.calendar) { await EmailCalendarPreparation.shared.remove(accountID: account.id) }
            tasksModel?.invalidateAccount(account.id)
            followUpsModel?.restoreAccount(account.id)
            automaticFollowUpsModel?.restoreAccount(account.id)
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
            let generation = syncActivityGeneration
            if canResumeFollowUps(in: mailbox, generation: generation) {
                await automaticFollowUps.start()
                if canResumeFollowUps(in: mailbox, generation: generation) { await followUps.resume() }
            }
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
    func enableFeature(_ feature: AccountFeature, for accountID: String, forceConsent: Bool = false) async throws -> FeatureGrant? {
        guard !isSigningIn, let accounts, let session = sessions[accountID], session.isSignedIn else { return nil }
        isSigningIn = true
        defer { isSigningIn = false }
        guard let stored = try await accounts.accounts().first(where: { $0.id == accountID }) else { return nil }
        // Several features use the same full-mail grant. Enabling another
        // covered feature changes local use without another consent screen.
        if !forceConsent, let granted = session.grantedScopes, GoogleScopes.isCovered(feature, by: granted) {
            return try await changeAccounts(returning: { [self] in
                guard sessions[accountID] === session, session.isSignedIn else { return nil }
                guard let updated = try await accounts.updateAccount(id: accountID, { account in
                    account.enabledFeatures = AccountFeature.names(of:
                        AccountFeature.named(account.enabledFeatures).union([feature]))
                }) else { return nil }
                await refreshInboxUpdates()
                await calendarModel?.refresh()
                tasksModel?.invalidateAccount(accountID)
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
            let updated = try await accounts.updateAccount(id: accountID) { account in
                // Features turned off while Google's page was open stay off.
                let wanted = AccountFeature.named(account.enabledFeatures).union([feature])
                account.grantedScopes = granted
                account.hostedDomain = hostedDomain
                account.enabledFeatures = AccountFeature.names(of: wanted.filter { GoogleScopes.isCovered($0, by: granted) })
            }
            if updated?.enabledFeatures.contains(AccountFeature.contacts.rawValue) != true {
                ContactThumbnailCache.shared.remove(accountID: accountID)
            }
            if updated?.enabledFeatures.contains(AccountFeature.calendar.rawValue) != true {
                await EmailCalendarPreparation.shared.remove(accountID: accountID)
            }
            await calendarModel?.refresh()
            tasksModel?.invalidateAccount(accountID)
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
                ContactThumbnailCache.shared.remove(accountID: accountID)
                try await cache.write { tx in try tx.deleteContacts(accountID: accountID) }
            }
            if feature == .tasks { await tasksModel?.removeAccount(accountID) }
            await refreshInboxUpdates()
            if feature == .calendar {
                await EmailCalendarPreparation.shared.remove(accountID: accountID)
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
            if !features.contains(AccountFeature.contacts.rawValue) { ContactThumbnailCache.shared.remove(accountID: record.id) }
            if !features.contains(AccountFeature.calendar.rawValue) { await EmailCalendarPreparation.shared.remove(accountID: record.id) }
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
        var revocations: [GrantRevocation] = []
        launchFailure = nil
        do {
            for account in try await accounts.accounts() {
                revocations += startRevokingGrants([(account, signedOut[account.id])])
                try await removeAccountData(account, session: signedOut[account.id])
            }
            phase = .signedOut
        } catch {
            launchFailure = .signOut
            phase = .failed(error.localizedDescription)
        }
        await reportUnrevokedGrants(revocations)
    }

    /// Signs out of one account while the others stay. The last account
    /// signs out of Tern.
    func signOut(of accountID: String) async {
        await changeAccounts { [self] in await signOutOfOne(accountID) }
    }

    private func signOutOfOne(_ accountID: String) async {
        guard let mailbox, mailbox.hasSeveralAccounts, accounts != nil, let owner = mailbox.account(id: accountID) else {
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
        let revocations = startRevokingGrants([(account, session)])
        var removalFailure: String?
        do {
            try await removeAccountData(account, session: session)
        } catch {
            // Once its record is gone, the next launch deletes what's left.
            let message = "Couldn't remove all local data for \(account.email)."
            mailbox.notice = MailboxModel.Notice(message: message, isError: true)
            removalFailure = message
        }
        await reportUnrevokedGrants(revocations, after: removalFailure)
    }

    /// A revocation under way for an account that's signing out.
    private struct GrantRevocation {
        let email: String
        let request: Task<Bool, Never>
    }

    /// Starts revoking the accounts' grants. Each request keeps its own copy
    /// of the refresh token, so removal deletes the stored one without waiting.
    private func startRevokingGrants(_ signingOut: [(account: AccountRecord, session: AccountSession?)]) -> [GrantRevocation] {
        guard let revocation = tokenRevocation else { return [] }
        return signingOut.compactMap { account, session in
            session?.startRevokingGrant(using: revocation).map { GrantRevocation(email: account.email, request: $0) }
        }
    }

    /// Hosted tests and UI audits never send Google a revocation.
    private var tokenRevocation: GoogleTokenRevocation? {
        launchMode.isIsolated ? nil : GoogleTokenRevocation()
    }

    /// Waits for the revocations, which give up after their own timeout, and
    /// says where to remove access that Google didn't confirm removing. What
    /// this sign-out already reported stays in the message.
    private func reportUnrevokedGrants(_ revocations: [GrantRevocation], after removalFailure: String? = nil) async {
        var unrevoked: [String] = []
        for revocation in revocations where !(await revocation.request.value) {
            unrevoked.append(revocation.email)
        }
        guard !unrevoked.isEmpty else { return }
        let message = "Google may still give Tern access to \(ListFormatter.localizedString(byJoining: unrevoked)). "
            + "To remove it, go to Google Account > Security > Your connections to third-party apps & services."
        reportSignInError([removalFailure, signInError, message].compactMap { $0 }.joined(separator: " "))
    }

    var canSignOut: Bool {
        switch phase {
        case .signedIn, .signInRequired: true
        case .loading, .signedOut, .failed: false
        }
    }

    var signOutMessage: String {
        Self.signOutMessage(outbox: mailbox?.outbox.count ?? 0, snoozed: mailbox?.snoozed.count ?? 0,
                            severalAccounts: mailbox?.hasSeveralAccounts == true)
    }

    /// The confirmation for one of several accounts, which counts only its own items.
    func signOutMessage(for account: AccountRecord) -> String {
        let owner = mailbox?.account(id: account.id)
        return Self.signOutMessage(outbox: owner?.outbox.count ?? 0, snoozed: owner?.snoozed.count ?? 0,
                                   severalAccounts: false)
    }

    private static func signOutMessage(outbox: Int, snoozed: Int, severalAccounts: Bool) -> String {
        let deletes = "Downloaded mail and pending changes will be deleted from this Mac"
        let deletion = switch outbox {
        case 0: deletes + "."
        case 1: deletes + ", including 1 message in the Outbox."
        case let count: deletes + ", including \(count) messages in the Outbox."
        }
        let message = deletion + (severalAccounts
            ? " Tern will also remove its access to your Google Accounts."
            : " Tern will also remove its access to your Google Account.")
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

    /// Keep local work accessible while this account waits for renewed access.
    private func sessionExpired(_ accountID: String) {
        guard let mailbox, mailbox.account(id: accountID) != nil else { return }
        inboxReconciliationRevision += 1
        let watcher = inboxWatchers.removeValue(forKey: accountID)
        Task { [weak self] in
            await watcher?.stop()
            await self?.refreshInboxUpdates()
        }
        accountsNeedingSignIn.insert(accountID)
        assistantModel?.refreshAccess()
        calendarModel?.accessExpired(accountID)
        tasksModel?.invalidateAccount(accountID)
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
    /// Maintenance, the calendar and the inbox watchers don't depend on one
    /// another, so they stop together and Quit waits for the slowest of
    /// them, not for each in turn.
    func prepareToQuit() async {
        meetingPreparation?.cancel()
        inboxUpdatesAreStopped = true
        syncActivityGeneration += 1
        todayModel?.endVisit()
        todayDashboardModel?.stop()
        automaticFollowUpsModel?.stop()
        maintenanceTask?.cancel()
        maintenanceTask = nil
        mailURLRouter?.stop()
        assistantModel?.stop()
        assistantModel?.connection.cancelSignIn()
        tasksModel?.stop()
        followUpsModel?.stop()
        let watchers = detachInboxWatchers()
        // A watcher only asks its account to sync, so nothing is lost while
        // its connection closes. Quit waits for that only when mail waits to
        // send or the Outbox can't be read, so no watcher asks for another
        // sync during the final send.
        let mailWaits = (try? await sendingDraftIDs().isEmpty) != true
        if !mailWaits {
            for watcher in watchers { Task { await watcher.stop() } }
        }
        let (maintenance, calendar) = (maintenanceModel, calendarModel)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await maintenance?.suspend() }
            group.addTask { await calendar?.stop() }
            guard mailWaits else { return }
            for watcher in watchers { group.addTask { await watcher.stop() } }
        }
    }

    /// A user can keep Tern open after its final send attempt fails.
    func cancelQuit() async {
        inboxUpdatesAreStopped = false
        let expectedMailbox = mailbox
        let generation = syncActivityGeneration
        maintenanceModel?.resume()
        await refreshInboxUpdates()
        await calendarModel?.start()
        tasksModel?.resume()
        if canResumeFollowUps(in: expectedMailbox, generation: generation) {
            await automaticFollowUpsModel?.start()
            if canResumeFollowUps(in: expectedMailbox, generation: generation) { await followUpsModel?.resume() }
            if canResumeFollowUps(in: expectedMailbox, generation: generation),
               destination == .today, NSApplication.shared.isActive {
                await todayModel?.beginVisit()
                if canResumeFollowUps(in: expectedMailbox, generation: generation) { await todayDashboardModel?.refresh() }
            }
        }
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

    private func mailboxService(for accountID: String) -> (any GmailService)? {
        if let session = sessions[accountID] { return GmailClient(tokens: session, gmailRequestBudget: session.gmailRequestBudget) }
#if TERN_TEST_SUPPORT || TERN_PERFORMANCE
        if launchMode.isIsolated {
            return accountID == "ui-audit-2" ? AuditGmail(.second) : AuditGmail()
        }
#endif
        return nil
    }

    /// Opens the window's mailbox with every signed-in account, starting in
    /// the combined Inbox when there are several.
    private func openMailbox(for records: [AccountRecord]) async {
        guard let cache, let accounts, let outgoingDirectory,
              let first = records.first, let gmail = mailboxService(for: first.id)
        else { return }
        await closeMailbox()
        // The loaded preferences say which accounts are paused, so opening
        // the mailbox waits on no config read.
        let preferences = accountPreferences
        let mailbox = MailboxModel(
            account: first, cache: cache, gmail: gmail,
            outgoingDirectory: outgoingDirectory, downloadsDirectory: cacheDownloadDirectory, snoozeStore: accounts,
            syncEnabled: preferences?.preferences(for: first.id).syncEnabled ?? true
        )
        configureMailRuntime(mailbox.defaultAccount)
        mailNotifications?.prepareAccount(first.id)
        for record in records.dropFirst() {
            guard let gmail = mailboxService(for: record.id) else { continue }
            mailNotifications?.prepareAccount(record.id)
            let syncEnabled = preferences?.preferences(for: record.id).syncEnabled ?? true
            await mailbox.addAccount(record, gmail: gmail, syncEnabled: syncEnabled, onCreate: configureMailRuntime)
        }
        if mailbox.hasSeveralAccounts { mailbox.selectedMailbox = .combined(SystemLabel.inbox) }
        // The loaded preferences also say which accounts are hidden. Applied
        // here, they leave the list's first read nothing to read twice.
        // Preferences that don't know an account yet, as after a first
        // sign-in, wait for their reconciliation as before.
        if let preferences, Set(records.map(\.id)).isSubset(of: preferences.records.map(\.id)) {
            mailbox.applyAccountPresentation(preferences: Array(preferences.preferencesByID.values),
                                             visibleAccountIDs: preferences.visibleAccountIDs)
        }
        // An empty list says "Downloading mail…" only for an account that
        // has never synced, so the window learns that before it shows the
        // mailbox.
        await mailbox.restoreSyncState()
        self.mailbox = mailbox
        bindMailNotificationRoutes()
        phase = .signedIn(first)
        // The saved mail shows at once. The engines start below, where they
        // always have.
        Task { await mailbox.startLocal() }
        schedulePreferenceReconciliation()
        mailURLRouter?.resume()
        await refreshInboxUpdates()
        startCacheMaintenance()
        // Spotlight lists up to 2,000 conversations per account. It starts
        // once the mailbox has, so that read queues behind the first rows.
        Task {
            await mailbox.start()
            guard self.mailbox === mailbox else { return }
            startSpotlight(for: mailbox)
        }
        for owner in mailbox.accounts {
            followUps.restoreAccount(owner.account.id)
            automaticFollowUps.restoreAccount(owner.account.id)
        }
        let generation = syncActivityGeneration
        if canResumeFollowUps(in: mailbox, generation: generation) {
            await automaticFollowUps.start()
            if canResumeFollowUps(in: mailbox, generation: generation) { await followUps.start() }
        }
    }

    /// Stops the open mailbox and waits for every mailbox still stopping.
    private func closeMailbox() async {
        meetingPreparation?.stop()
        meetingPreparation = nil
        syncActivityGeneration += 1
        organizationSessionsModel?.clear()
        todayModel?.endVisit()
        todayDashboardModel?.reset()
        automaticFollowUpsModel?.stop()
        followUpsModel?.stop()
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

    /// Checkpoints deletion intent and file identities before removing records.
    private func removeAccountData(
        _ account: AccountRecord, session: AccountSession?
    ) async throws {
        meetingPreparation?.stop()
        meetingPreparation = nil
        assistantModel?.forgetAccount(account.id)
        await mailNotifications?.removeAccount(account.id)
        // The share folder isn't sorted by account, so this clears every
        // account's files. Share services already hold their own copies.
        await TemporaryShareFile.removeAll()
        try await scheduleAccountRemoval(accountID: account.id, session: session)
    }

    /// Finishes the sign-outs an earlier run left partway, then deletes what
    /// is left of accounts that aren't signed in. A sign-out that still
    /// can't finish is reported.
    private func finishInterruptedRemovals(keeping signedIn: Set<String>) async throws {
        if try await cleanupCoordinator().retryPending() == false {
            reportSignInError(AccountRemovalError.incomplete.localizedDescription)
        }
        try await removeLeftovers(keeping: signedIn)
    }

    /// Deletes what the cache and disk still hold for accounts that aren't
    /// signed in, such as one whose sign-out stopped partway.
    private func removeLeftovers(keeping signedIn: Set<String>) async throws {
        guard let cache else { return }
        guard let accounts else { return }
        let pending = Set(try await accounts.pendingAccountRemovals().map(\.accountID))
        let stale = try await cache.read { tx in try tx.cachedAccountIDs() }.subtracting(signedIn.union(pending))
        for accountID in stale { try await scheduleAccountRemoval(accountID: accountID, session: nil) }
    }

    private func scheduleAccountRemoval(accountID: String, session: AccountSession?) async throws {
        guard let cache else { throw AccountRemovalError.incomplete }
        let draftIDs = try await cache.read { tx in Set(try tx.localDrafts(accountID: accountID).map(\.id)) }
        let complete = try await cleanupCoordinator().remove(accountID: accountID, draftIDs: draftIDs) {
            await session?.invalidateForRemoval()
        }
        if !complete { reportSignInError(AccountRemovalError.incomplete.localizedDescription) }
    }

    private func cleanupCoordinator() throws -> AccountCleanupCoordinator {
        if let accountCleanup { return accountCleanup }
        guard let accounts else { throw AccountRemovalError.incomplete }
        let isolated = launchMode.isIsolated
        let calendarURL = isolated ? nil : try Self.dataDirectory().appending(path: "calendar.sqlite")
        let coordinator = AccountCleanupCoordinator(store: accounts, downloadsRoot: cacheDownloadDirectory,
            outgoingRoot: outgoingDirectory, operations: .init(
                removeAccount: { [weak self] accountID in
                    await self?.calendarModel?.removeAccount(accountID)
                    await self?.tasksModel?.removeAccount(accountID)
                    await self?.automaticFollowUpsModel?.removeAccount(accountID)
                    await self?.followUpsModel?.removeAccount(accountID)
                    if let calendarURL {
                        try await AccountCleanupCoordinator.removeCalendarCache(accountID: accountID, at: calendarURL,
                            openStore: self?.calendarModel?.store)
                    }
                    try await accounts.deleteAccount(id: accountID)
                },
                removeCredentials: { accountID in
                    if !isolated { try await KeychainStore.delete(account: accountID) }
                },
                removeCache: { [weak self] accountID in
                    guard let self else { throw AccountRemovalError.incomplete }
                    try await removeCachedData(accountIDs: [accountID])
                },
                removeWritingStyle: { accountID in
                    if !isolated { try await AssistantWritingStyleCleanup.erase(accountID: accountID) }
                }
            ))
        accountCleanup = coordinator
        return coordinator
    }

    /// File deletion runs separately using the manifest's durable draft IDs.
    private func removeCachedData(accountIDs: Set<String>) async throws {
        meetingPreparation?.stop()
        meetingPreparation = nil
        guard let cache else { throw AccountRemovalError.incomplete }
        for accountID in accountIDs {
            ReaderCacheLifecycle.invalidate(accountID: accountID)
            ContactThumbnailCache.shared.remove(accountID: accountID)
            await EmailCalendarPreparation.shared.remove(accountID: accountID)
        }
        AttachmentPresentation.removeAll()
        spotlight.remove(accountIDs: accountIDs)
        try await cache.write { tx in
            for accountID in accountIDs {
                try tx.deleteAccountData(accountID: accountID)
            }
        }
    }

    private static func dataDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appending(path: "Tern", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Mail bodies and unsent drafts are plaintext SQLite data. Keep the
        // app-owned directory private even if its containing path is copied or
        // its sandbox container permissions change.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
        case .tasks: "Google Tasks"
        }
    }
}
