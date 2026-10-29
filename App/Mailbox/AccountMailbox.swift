import Accessibility
import AppKit
import Foundation
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

    static let cacheFailure = "Tern couldn't read its mail cache."

    let account: AccountRecord
    let engine: SyncEngine
    /// Wakes this account's snoozes. Nil when there's no config store.
    @ObservationIgnored let snoozeKeeper: SnoozeKeeper?

    private(set) var labels: [LabelRecord] = []
    /// Drafts and sends that haven't reached Gmail, or that Gmail refused.
    private(set) var outbox: [DraftActivity] = []
    /// Snoozed conversations, the soonest to wake first.
    private(set) var snoozed: [SnoozedThread] = []
    /// Conversations a snooze brought back that are still in the Inbox.
    private(set) var wokenThreadIDs: Set<String> = []
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var hasSyncedOnce = false

    /// Called after `labels` changes.
    @ObservationIgnored var onLabelsChange: (() -> Void)?
    /// Called after `snoozed` changes.
    @ObservationIgnored var onSnoozedChange: (() -> Void)?
    /// Engine events that aren't about syncing, which the window shows.
    @ObservationIgnored var onEvent: ((SyncEvent) -> Void)?

    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// `outgoingDirectory` holds copies of the files attached to drafts.
    /// `snoozeStore` keeps the durable copy of snoozes; without it the
    /// account can't snooze.
    init(account: AccountRecord, cache: MailCache, gmail: any GmailService, outgoingDirectory: URL, snoozeStore: AccountStore?) {
        self.account = account
        self.cache = cache
        let engine = SyncEngine(
            accountID: account.id,
            sender: EmailAddress(name: account.displayName, address: account.email),
            outgoingDirectory: outgoingDirectory,
            gmail: gmail,
            cache: cache
        )
        self.engine = engine
        snoozeKeeper = snoozeStore.map { SnoozeKeeper(engine: engine, accounts: $0) }
    }

    func start() async {
        hasSyncedOnce = (try? await cache.syncState(accountID: account.id)) != nil
        guard !isStopped else { return }
        let labelStream = cache.labels(accountID: account.id)
        let outboxStream = cache.outbox(accountID: account.id)
        let snoozedStream = cache.snoozedThreads(accountID: account.id)
        let wokenStream = cache.wokenThreadIDs(accountID: account.id)
        let events = engine.events
        observe(labelStream) { $0.labels = $1; $0.onLabelsChange?() }
        observe(outboxStream) { $0.outbox = $1 }
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

    /// Stops the keeper, the streams and then the engine, since the keeper
    /// writes through the engine. Returns once nothing writes to the cache.
    func stop() async {
        isStopped = true
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        await snoozeKeeper?.stop()
        tasks.forEach { $0.cancel() }
        tasks = []
        await engine.stop()
    }

    func syncNow() {
        let engine = engine
        Task { await engine.syncReportingErrors() }
    }

    /// Wakes what is due. Runs after each sync pass and when the Mac wakes.
    func checkSnoozes() {
        guard let keeper = snoozeKeeper, !isStopped else { return }
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
        switch event {
        case .syncStarted:
            syncStatus = .syncing
        case .syncFinished(let date):
            syncStatus = .idle
            lastSyncedAt = date
            hasSyncedOnce = true
            // A pass can bring new mail that ends a snooze early.
            checkSnoozes()
        case .syncFailed(let message):
            syncStatus = .failed(message)
        case .actionFailed, .draftFailed, .draftCopied, .draftSent:
            onEvent?(event)
        }
    }
}
