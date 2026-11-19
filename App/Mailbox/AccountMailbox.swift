import Accessibility
import AppKit
import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine

/// One signed-in account: its sync engine, its snooze keeper and the cache
/// streams that don't depend on what the window shows. The window's
/// `MailboxModel` reads it and sends it actions.
@MainActor
@Observable
final class AccountMailbox {
    enum SyncStatus: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    static let cacheFailure = "Couldn't load saved mail."

    let account: AccountRecord
    /// A paused runtime observes local mail and accepts draft/queue edits,
    /// while a replacement runtime resumes network work later.
    let syncEnabled: Bool
    let engine: SyncEngine
    @ObservationIgnored let people: PeopleClient?
    /// A rejected directory stays off for this account until the next launch.
    @ObservationIgnored var isDirectorySearchUnavailable = false
    /// Wakes this account's snoozes. Nil when there's no config store.
    @ObservationIgnored let snoozeKeeper: SnoozeKeeper?

    private(set) var labels: [LabelRecord] = []
    /// Row badges need label appearance, not the frequently changing counts.
    /// Keeping this separately avoids invalidating every mail row on each read.
    private(set) var listLabels: [LabelRecord] = []
    /// Expansion and selection queries share one hierarchy per label snapshot.
    private(set) var sidebarLabelOutline: [LabelNode] = []
    /// Drafts and sends that haven't reached Gmail, or that Gmail refused.
    private(set) var outbox: [DraftActivity] = []
    /// Snoozed conversations, the soonest to wake first.
    private(set) var snoozed: [SnoozedThread] = []
    /// Conversations a snooze brought back that are still in the Inbox.
    private(set) var wokenThreadIDs: Set<String> = []
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var hasSyncedOnce = false

    /// Called when label membership or appearance changes; counts are separate.
    @ObservationIgnored var onLabelsChange: (() -> Void)?
    /// Called after `snoozed` changes.
    @ObservationIgnored var onSnoozedChange: (() -> Void)?
    /// Engine events that aren't about syncing, which the window shows.
    @ObservationIgnored var onEvent: ((SyncEvent) -> Void)?
    /// Receives only committed baseline/history snapshots for new-mail alerts.
    @ObservationIgnored var onMailSync: ((MailSyncNotification) async -> Void)?
    @ObservationIgnored var onUnreadCountChange: (() -> Void)?
    /// Keeps the app out of App Nap while this account syncs or sends.
    @ObservationIgnored var activityGuard: SyncActivityGuard?
    /// The senders this account lets load remote images. It lives and dies with the account object.
    @ObservationIgnored let imageSenders: ImageSenderAllowSet

    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// The local start. The network start waits for it.
    @ObservationIgnored private var localStart: Task<Void, Never>?
    @ObservationIgnored private var hasReadSavedState = false
    @ObservationIgnored private var isNetworkStarted = false
    /// Engine settings go in the order they were made.
    @ObservationIgnored private var control: Task<Void, Never>?

    /// `outgoingDirectory` holds copies of the files attached to drafts.
    /// `snoozeStore` keeps snoozes, identities and feature settings. Without
    /// it, snoozes, identity refresh and contact sync are unavailable.
    init(account: AccountRecord, cache: MailCache, gmail: any GmailService, outgoingDirectory: URL, snoozeStore: AccountStore?, syncEnabled: Bool = true) {
        self.account = account
        imageSenders = ImageSenderAllowSet(accountID: account.id)
        self.syncEnabled = syncEnabled
        self.cache = cache
        let people = (gmail as? GmailClient).map { PeopleClient(session: $0.session) }
        self.people = people
        let engine = SyncEngine(
            accountID: account.id,
            sender: EmailAddress(name: account.displayName, address: account.email),
            outgoingDirectory: outgoingDirectory,
            gmail: gmail,
            people: people,
            accounts: snoozeStore,
            cache: cache,
            sendsAutomatically: syncEnabled,
            indexesAttachmentsAutomatically: syncEnabled
                && (!LaunchMode.current.isIsolated || LaunchMode.current.audit.attachments)
        )
        self.engine = engine
        snoozeKeeper = snoozeStore.map { SnoozeKeeper(engine: engine, accounts: $0) }
    }

    /// Shows the saved mail, then starts syncing.
    func start() async {
        await startLocal()
        await startNetwork()
    }

    /// Shows what the cache holds: labels, the outbox and snoozes. It starts
    /// no engine, so the window can show it before anything syncs.
    func startLocal() async {
        if localStart == nil {
            guard !isStopped else { return }
            localStart = Task { [weak self] in await self?.observeCache() }
        }
        await localStart?.value
    }

    /// Starts the engine and the snooze keeper. The local start always ends
    /// first, so saved label icons are migrated before the engine clears
    /// old aliases.
    func startNetwork() async {
        await startLocal()
        guard syncEnabled, !isStopped, !isNetworkStarted else { return }
        isNetworkStarted = true
        // Snoozes that came due while the Mac slept wake when it does.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, as requested above.
            MainActor.assumeIsolated { self?.checkSnoozes() }
        }
        await engine.start()
        guard !isStopped else { return }
        await snoozeKeeper?.start()
    }

    /// Reads whether this account has ever finished a sync and, until the
    /// cache observation starts, its labels. An empty list says "Downloading
    /// mail…" only for an account that hasn't synced, and the sidebar shows
    /// the labels in its first frame, so opening a mailbox reads both before
    /// the window shows it. Only the first call reads.
    func restoreSavedState() async {
        guard !hasReadSavedState else { return }
        hasReadSavedState = true
        let accountID = account.id
        // Once the observation has started, its labels are the newer ones.
        let readsLabels = localStart == nil
        // Labels that fail to load don't hide the sync state. The
        // observation reports that failure when it starts.
        let saved = try? await cache.read { tx in
            (hasSynced: try tx.syncState(accountID: accountID) != nil,
             labels: readsLabels ? (try? tx.displayedLabels(accountID: accountID)) : nil)
        }
        guard let saved else { return }
        // A sync that finished during the read has already set the flag.
        if saved.hasSynced { hasSyncedOnce = true }
        if let labels = saved.labels, localStart == nil, !isStopped { show(labels) }
    }

    /// Puts a label snapshot in the sidebar, the pickers and the list's badges.
    private func show(_ labels: [LabelRecord]) {
        self.labels = labels
        let outline = LabelNode.outline(labels.filter { !$0.isSystem && LabelNode.isVisibleInSidebar($0) })
        if sidebarLabelOutline != outline { sidebarLabelOutline = outline }
        let presentation = labels.map { label in
            var value = label
            value.threadsTotal = nil
            value.threadsUnread = nil
            value.messagesTotal = nil
            value.messagesUnread = nil
            return value
        }
        if listLabels != presentation {
            listLabels = presentation
            onLabelsChange?()
        }
        onUnreadCountChange?()
    }

    private func observeCache() async {
        guard !isStopped else { return }
        // The streams start first, so the sidebar's labels and counts don't
        // wait for the reads below.
        let labelStream = cache.labels(accountID: account.id)
        let outboxStream = cache.outbox(accountID: account.id)
        let snoozedStream = cache.snoozedThreads(accountID: account.id)
        let wokenStream = cache.wokenThreadIDs(accountID: account.id)
        let events = engine.events
        observe(labelStream) { $0.show($1) }
        observe(outboxStream) { mailbox, outbox in
            mailbox.outbox = outbox
            mailbox.activityGuard?.update(.send(accountID: mailbox.account.id), isActive: outbox.contains(where: \.isSending))
        }
        observe(snoozedStream) { $0.snoozed = $1; $0.onSnoozedChange?() }
        var isFirstWoken = true
        observe(wokenStream) { mailbox, woken in
            let back = woken.subtracting(mailbox.wokenThreadIDs).count
            mailbox.wokenThreadIDs = woken
            if !isFirstWoken, back > 0 {
                let subject = back == 1 ? "A snoozed conversation is" : "\(back) snoozed conversations are"
                AccessibilityNotification.Announcement("\(subject) back in the Inbox").post()
            }
            isFirstWoken = false
        }
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
        let notifications = engine.mailNotifications
        tasks.append(Task { [weak self] in
            for await notification in notifications {
                guard let self, !isStopped, !Task.isCancelled else { return }
                await onMailSync?(notification)
            }
        })
        // Does nothing when opening the mailbox already read it. Otherwise it
        // reads only the sync state, since the label stream has started.
        await restoreSavedState()
        guard !isStopped else { return }
        // The engine clears old aliases on startup. Migrate saved icons first.
        await LabelAppearance.shared.reconcile(using: cache)
    }

    /// Stops the keeper, the streams and then the engine, since the keeper
    /// writes through the engine. Returns once nothing writes to the cache.
    func stop() async {
        isStopped = true
        activityGuard?.release(accountID: account.id)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        await snoozeKeeper?.stop()
        tasks.forEach { $0.cancel() }
        tasks = []
        await engine.stop()
    }

    /// Check for New Mail, and Try Again after a failure.
    func syncNow() {
        tell { await $0.requestSync(reason: .manual) }
    }

    /// What the user is doing, which sets how often the engine checks for mail.
    func setActivity(_ activity: SyncActivity) {
        tell { await $0.setActivity(activity) }
    }

    /// Whether IMAP reports Inbox changes as they happen.
    func setPushAvailable(_ available: Bool) {
        tell { await $0.setPushAvailable(available) }
    }

    private func tell(_ body: @escaping @Sendable (SyncEngine) async -> Void) {
        guard syncEnabled, !isStopped else { return }
        let engine = engine
        let previous = control
        control = Task {
            await previous?.value
            await body(engine)
        }
    }

    /// Wakes what is due. Runs after each sync pass and when the Mac wakes.
    func checkSnoozes() {
        guard let keeper = snoozeKeeper, syncEnabled, !isStopped else { return }
        Task { await keeper.check() }
    }

    /// A list stream the window runs for this account failed.
    func cacheReadFailed() {
        syncStatus = .failed(Self.cacheFailure)
    }

    private func observe<Value: Sendable>(
        _ stream: AsyncThrowingStream<Value, any Error>,
        _ update: @escaping @MainActor (AccountMailbox, Value) -> Void
    ) {
        tasks.append(Task { [weak self] in
            do {
                for try await value in stream {
                    guard let self, !Task.isCancelled, !isStopped else { return }
                    update(self, value)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.cacheReadFailed()
            }
        })
    }

    private func handle(_ event: SyncEvent) {
        guard !isStopped, !Task.isCancelled else { return }
        switch event {
        case .syncStarted:
            syncStatus = .syncing
            activityGuard?.update(.pass(accountID: account.id), isActive: true)
        case .syncFinished(let date):
            syncStatus = .idle
            lastSyncedAt = date
            hasSyncedOnce = true
            activityGuard?.update(.pass(accountID: account.id), isActive: false)
            // A pass can bring new mail that ends a snooze early.
            checkSnoozes()
        case .syncFailed(let message):
            syncStatus = .failed(message)
            activityGuard?.update(.pass(accountID: account.id), isActive: false)
        case .actionFailed, .draftFailed, .draftCopied, .draftSent:
            onEvent?(event)
        }
    }
}
