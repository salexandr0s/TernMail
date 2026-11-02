import Foundation
import GmailAPI
import MailStore
import MessageContent
import os

public enum SyncEvent: Sendable, Equatable {
    case syncStarted
    case syncFinished(Date)
    case syncFailed(String)
    /// Gmail refused a change for good. A conversation or label goes back
    /// to how it was; for a settings change, the message names what Gmail
    /// didn't save.
    case actionFailed(String)
    /// A draft was sent.
    case draftSent(localDraftID: String)
    /// Gmail refused a draft, or it was sent or deleted in another app. The
    /// draft is back to editing, and its window shows `message`.
    case draftFailed(localDraftID: String, message: String)
    /// Another app changed the draft's Gmail copy, so Tern kept that one and
    /// saves this draft as a new one.
    case draftCopied(localDraftID: String)
}

enum SyncError: Error, Equatable {
    case invalidHistoryID
}

/// Keeps one account's cache in step with Gmail, sends queued changes and
/// refreshes the account's identities and contacts.
///
/// Passes run one at a time. The first download publishes complete chunks so
/// mail is available while it continues. A history pass commits each page as
/// it arrives and moves the cursor only as far as the records it has stored;
/// a reset pass commits once, at the end.
/// How long each kind of change waits in the queue before it goes to Gmail.
/// A change still waiting is undone by deleting its row; one that has gone
/// out is undone with the inverse change, which costs one more request. The
/// defaults send everything at once, so a change shows in Gmail as soon as
/// it shows in Tern. Sending a draft has its own delay in `ComposeQueue`.
public struct UndoHolds: Sendable, Equatable {
    /// Archive, trash, read, star, snooze and label edits on conversations and messages.
    public var triage: TimeInterval
    /// Creating, renaming, recoloring and hiding labels.
    public var labels: TimeInterval
    /// Filters, the vacation responder and signatures.
    public var settings: TimeInterval

    public init(triage: TimeInterval = 0, labels: TimeInterval = 0, settings: TimeInterval = 0) {
        self.triage = triage
        self.labels = labels
        self.settings = settings
    }

    /// Every kind waits `seconds`, for tests of the hold itself.
    public static func uniform(_ seconds: TimeInterval) -> UndoHolds {
        UndoHolds(triage: seconds, labels: seconds, settings: seconds)
    }
}

public actor SyncEngine {
    /// The threading headers let a reply answer a message without fetching it.
    static let metadataHeaders = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To", "References", "Reply-To", "Content-Type"]
    static let inboxCap = 5000
    /// Releasing a search hold keeps what this lists, so both use one window.
    static let recentQuery = "newer_than:\(CacheHolds.recentDays)d"
    /// Metadata fetched per request group during a full sync.
    static let fullSyncChunk = 25
    /// How long a complete label listing stays current. Until then a pass
    /// refreshes only the labels its history touched.
    static let labelRefreshInterval: TimeInterval = 5 * 60
    /// How often identities and contacts refresh while the engine runs.
    static let peopleRefreshInterval: Duration = .seconds(6 * 60 * 60)

    public nonisolated let events: AsyncStream<SyncEvent>
    let continuation: AsyncStream<SyncEvent>.Continuation
    public nonisolated let mailNotifications: AsyncStream<MailSyncNotification>
    let mailNotificationContinuation: AsyncStream<MailSyncNotification>.Continuation
    let accountID: String
    /// The From address of every draft.
    let sender: EmailAddress
    /// Where compose windows copy attached files. `OutgoingAttachment.path` is relative to it.
    let outgoingDirectory: URL
    let gmail: any GmailService
    /// Filter, vacation and signature calls. Without them, settings rows wait.
    let settings: (any SettingsService)?
    let triage: (any TriageService)?
    /// The send-as list. Without it, identities aren't refreshed.
    let identities: (any IdentityService)?
    /// Contact lists. Without them, contacts aren't synced.
    let people: (any PeopleService)?
    /// The config store, which keeps identities and signatures for compose
    /// and says whether Contacts is on. Without it, identities aren't
    /// refreshed, contacts aren't synced, and a signature Gmail accepted
    /// isn't recorded.
    let accounts: AccountStore?
    let cache: MailCache
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    let undoHolds: UndoHolds
    let sendsAutomatically: Bool
    let indexesAttachmentsAutomatically: Bool

    /// The running pass. It clears itself, so a caller that resumes after it
    /// ends never joins a finished pass.
    private(set) var pass: Task<Bool, any Error>?
    /// When the labels were last listed in full. Nil makes the next pass list
    /// them again: at launch, after a local label change, and after a refresh
    /// failed.
    var labelsRefreshedAt: Date?
    private var labelRefreshGeneration = UUID()
    private var pollTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?
    /// What the user is doing, from the app. Sets the poll interval.
    private(set) var activity: SyncActivity = .active
    /// Whether IMAP reports Inbox changes as they happen, from the app.
    private(set) var pushAvailable = false
    /// When the last pass began, whatever asked for it. One within
    /// `SyncSchedule.activationThrottle` serves an activation request.
    var lastPassStartedAt: Date?
    var attachmentIndexTask: Task<Void, Never>?
    var attachmentIndexPass: Task<AttachmentIndexState, any Error>?
    var attachmentClassificationPass: Task<Int, any Error>?
    /// Runs the passes `requestSync(reason:)` asks for, then clears itself.
    var requestedPasses: Task<Void, Never>?
    /// The retries of the requests waiting for a pass: the longest list
    /// among them. Nil when nothing waits.
    var pendingRetries: [Duration]?
    /// Waits out `SyncSchedule.afterActionDebounce` after a delivered change,
    /// then asks for a pass.
    var afterActionTask: Task<Void, Never>?
    /// The sleeps `wake(_:)` can cut short.
    var sleepers: [Sleeper: Task<Bool, Never>] = [:]
    var contactSyncTask: Task<Void, any Error>?
    var lastContactSyncAt: Date?
    /// When each source's last full contact sync began, failed ones included.
    /// Kept for the engine's lifetime only.
    var fullContactSyncStarts: [ContactSource: Date] = [:]
    var readingLoads: [String: ReadingLoad] = [:]
    var retiredReadingLoads: [UUID: Task<Void, any Error>] = [:]
    var prefetchTask: Task<Void, Never>?
    var prefetchTargets: [String] = []
    var prefetchGeneration = UUID()
    private var hasStarted = false
    private var writesInFlight = 0
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    var drainTasks: [PendingAction.Lane: Task<Void, Never>] = [:]
    var wakeRequests = Set<PendingAction.Lane>()
    /// A drain task asleep until its lane's next row is due, or until a new
    /// row or an undo wakes it. See `sleepUntilWoken(_:limit:)`.
    var laneWaiters: [PendingAction.Lane: LaneWaiter] = [:]
    var laneWaiterGeneration: UInt64 = 0
    /// Sends under way, so `stop()` can let them finish. The drain task and
    /// `sendWaitingDraftsNow()` can each be running one.
    var sendsInFlight = 0
    var sendWaiters: [CheckedContinuation<Void, Never>] = []
    /// Calls of `sendDueActions()` under way. Only a call with none beside it
    /// may take a label row still marked as going out for one that lost its
    /// outcome.
    var labelSendsInFlight = 0
    /// Set when Gmail rejected the account's sign-in during a send. The send
    /// loops wait until `resumeAfterSignIn()`; a direct `sendDueActions()`
    /// still tries.
    var waitsForSignIn = false
    /// Set by `stop()`: the compose lane starts no further rows.
    var isStoppingDrafts = false
    /// Earliest next save per local draft. Large messages save at most every
    /// `largeSaveInterval`, since each save uploads the attachments again.
    var nextLargeSave: [String: Date] = [:]
    /// Undo receipts exist only for this engine's lifetime. Remember rejected
    /// and consumed row IDs even after history has removed the queue rows.
    var unavailableUndoIDs = Set<Int64>()
    var undoReceipts: [Int64: [WeakActionReceipt]] = [:]
    private(set) var isStopped = false
    /// Set as `stop()` begins. A lock, so another engine's write that adds
    /// rows for this account can check it inside its transaction.
    let stopRequested = OSAllocatedUnfairLock(initialState: false)
    /// Accessed only inside the cache's serialized writes. The lock safely
    /// carries deletion knowledge into their Sendable closures. Gmail message
    /// IDs are never reused; forgetting one could resurrect deleted mail, so
    /// `Tombstones` keeps the newest 20,000.
    let deletedMessageIDs = OSAllocatedUnfairLock(initialState: Tombstones())
    /// Conversations an open search or list shows. A lock, so the write that
    /// releases expired holds reads the set as it is then.
    let visibleThreadIDs = OSAllocatedUnfairLock(initialState: Set<String>())

    /// - Parameters:
    ///   - settings: Defaults to `gmail` when it makes the settings calls.
    ///   - identities: Defaults to `gmail` when it lists send-as addresses.
    ///   - undoHolds: How long each kind of change waits before it is sent, so undo can cancel it.
    ///   - sendsAutomatically: Whether the engine sends queued rows itself and syncs after
    ///     each sent change. Tests turn this off and call `sendDueActions()` and `sync()`.
    ///   - sleep: Waits between retries. Tests replace it to skip the wait.
    public init(
        accountID: String,
        sender: EmailAddress,
        outgoingDirectory: URL,
        gmail: any GmailService,
        settings: (any SettingsService)? = nil,
        triage: (any TriageService)? = nil,
        identities: (any IdentityService)? = nil,
        people: (any PeopleService)? = nil,
        accounts: AccountStore? = nil,
        cache: MailCache,
        undoHolds: UndoHolds = UndoHolds(),
        sendsAutomatically: Bool = true,
        indexesAttachmentsAutomatically: Bool = false,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.sender = sender
        self.outgoingDirectory = outgoingDirectory
        self.gmail = gmail
        self.settings = settings ?? gmail as? any SettingsService
        self.triage = triage ?? gmail as? any TriageService
        self.identities = identities ?? gmail as? any IdentityService
        self.people = people
        self.accounts = accounts
        self.cache = cache
        self.undoHolds = undoHolds
        self.sendsAutomatically = sendsAutomatically
        self.indexesAttachmentsAutomatically = indexesAttachmentsAutomatically
        self.sleep = sleep
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SyncEvent.self, bufferingPolicy: .bufferingNewest(16))
        (mailNotifications, mailNotificationContinuation) = AsyncStream.makeStream(of: MailSyncNotification.self, bufferingPolicy: .bufferingNewest(32))
    }

    // MARK: Scheduling

    /// Resumes interrupted sends, syncs now and then on `SyncSchedule`'s
    /// interval for the current activity, and refreshes identities and
    /// contacts now and every 6 hours.
    public func start() async {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        let accountID = accountID
        do {
            try await write { tx in
                try tx.requeueInterruptedActions(accountID: accountID)
                try tx.clearLabelAliases(accountID: accountID)
            }
        } catch {
            hasStarted = false
            if !isStopped { continuation.yield(.syncFailed(Self.message(for: error))) }
            return
        }
        guard !isStopped else { return }
        scheduleSending()
        requestSync(reason: .poll)
        pollTask = Task { await runPolling() }
        peopleTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPeople()
                try? await Task.sleep(for: Self.peopleRefreshInterval)
                if self == nil { return }
            }
        }
    }

    /// Errors wait for the next run, since the window has no status for
    /// identities or contacts.
    private func refreshPeople() async {
        try? await refreshIdentities()
        try? await syncContacts()
    }

    /// Cancels polling, sending, refreshing and any running pass, and returns
    /// once they have finished, so the caller can delete the account's data
    /// safely. A send that is already uploading finishes first, so its
    /// outcome is known.
    public func stop() async {
        stopRequested.withLock { $0 = true }
        isStoppingDrafts = true
        if sendsInFlight > 0 {
            await withCheckedContinuation { sendWaiters.append($0) }
        }
        isStopped = true
        let background = [pollTask, peopleTask, requestedPasses, afterActionTask, attachmentIndexTask, prefetchTask].compactMap { $0 }
        for sleeper in sleepers.values { sleeper.cancel() }
        prefetchTargets = []
        let reading = Array(readingLoads.values.map(\.task)) + Array(retiredReadingLoads.values)
        reading.forEach { $0.cancel() }
        background.forEach { $0.cancel() }
        let attachmentPass = attachmentIndexPass
        attachmentPass?.cancel()
        let classificationPass = attachmentClassificationPass
        classificationPass?.cancel()
        let contacts = contactSyncTask
        contacts?.cancel()
        let drains = Array(drainTasks.values)
        drains.forEach { $0.cancel() }
        // A cancelled drain asleep on its lane must wake to see the cancellation.
        let waiters = Array(laneWaiters.values)
        laneWaiters = [:]
        waiters.forEach { $0.continuation.resume() }
        let running = pass
        running?.cancel()
        for drain in drains { await drain.value }
        for task in background { await task.value }
        _ = try? await contacts?.value
        _ = try? await running?.value
        _ = try? await attachmentPass?.value
        for task in reading { _ = try? await task.value }
        _ = try? await classificationPass?.value
        if writesInFlight > 0 {
            await withCheckedContinuation { writeWaiters.append($0) }
        }
        // Keep handles until teardown ends so another stop() joins the same work.
        pollTask = nil
        prefetchTask = nil
        peopleTask = nil
        attachmentIndexTask = nil
        drainTasks = [:]
        continuation.finish()
        mailNotificationContinuation.finish()
    }

    /// Every engine write goes through here, so nothing lands after `stop()`.
    func write<T: Sendable>(_ updates: @escaping @Sendable (CacheTransaction) throws -> T) async throws -> T {
        try await gated { try await cache.write(updates) }
    }

    /// Runs a write to the cache or the config store unless the engine has
    /// stopped. `stop()` waits for it to finish.
    func gated<T: Sendable>(_ write: () async throws -> T) async throws -> T {
        if isStopped || Task.isCancelled { throw CancellationError() }
        writesInFlight += 1
        defer {
            writesInFlight -= 1
            if writesInFlight == 0 {
                let waiters = writeWaiters
                writeWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        return try await write()
    }

    /// Runs a pass and reports the outcome on `events` instead of throwing.
    public func syncReportingErrors() async {
        _ = await reportingErrors { try await joinOrStartPass() }
    }

    /// Runs one pass, or waits for the pass already running.
    public func sync() async throws {
        _ = try await joinOrStartPass()
    }

    /// Asks for a pass. A pass already running may have started too early to
    /// see what `reason` reports, so one more runs afterward, however many
    /// requests arrive meanwhile. An Inbox signal whose pass finds nothing
    /// tries again after 1 and 3 seconds; an activation within 5 seconds of
    /// the last pass is already served; a delivered change waits half a
    /// second for the next one.
    public func requestSync(reason: SyncReason) {
        guard !isStopped else { return }
        switch reason {
        case .poll, .manual:
            requestPass(retries: [])
        case .inboxSignal:
            requestPass(retries: SyncSchedule.inboxSignalRetries)
        case .activation:
            if let started = lastPassStartedAt, now().timeIntervalSince(started) < SyncSchedule.activationThrottle { return }
            requestPass(retries: [])
        case .afterAction:
            wake(.afterAction)
            guard afterActionTask == nil else { return }
            afterActionTask = Task { await runAfterActionDebounce() }
        }
    }

    func requestPass(retries: [Duration]) {
        guard !isStopped else { return }
        if retries.count > (pendingRetries?.count ?? -1) { pendingRetries = retries }
        wake(.retry)
        guard requestedPasses == nil else { return }
        requestedPasses = Task { await runRequestedPasses() }
    }

    /// Sets the poll interval. Coming to the front lists every label again
    /// and asks for a pass, so counts that moved while the app was behind
    /// show at once.
    public func setActivity(_ new: SyncActivity) {
        guard !isStopped, new != activity else { return }
        let wasActive = activity == .active
        activity = new
        wake(.poll)
        if new == .active, !wasActive { requestLabelRefresh() }
    }

    /// Whether IMAP reports Inbox changes as they happen. While it does, the
    /// engine polls every 5 minutes instead of every 15 or 60 seconds.
    public func setPushAvailable(_ available: Bool) {
        guard !isStopped, available != pushAvailable else { return }
        pushAvailable = available
        wake(.poll)
    }

    /// Lists every label on the next pass, and asks for one as an activation.
    public func requestLabelRefresh() {
        invalidateLabels()
        requestSync(reason: .activation)
    }

    func invalidateLabels() {
        labelsRefreshedAt = nil
        labelRefreshGeneration = UUID()
    }

    /// Returns once no pass is running. Background work waits here so a pass
    /// never queues behind it.
    func waitForPassToEnd() async {
        while let running = pass { _ = try? await running.value }
    }

    /// Returns whether the pass found changes.
    func joinOrStartPass() async throws -> Bool {
        try Task.checkCancellation()
        if isStopped { throw CancellationError() }
        if let pass {
            let changed = try await pass.value
            try Task.checkCancellation()
            return changed
        }
        lastPassStartedAt = now()
        let task = Task {
            defer {
                pass = nil
                // Polling counts from here.
                wake(.poll)
            }
            let changed = try await GmailRequestBudget.$priority.withValue(.sync) { try await runPass() }
            // The pass reached Gmail, so the account's sign-in works again.
            if waitsForSignIn { await resumeAfterSignIn() }
            return changed
        }
        pass = task
        let changed = try await task.value
        try Task.checkCancellation()
        return changed
    }

    /// Reports `pass` on `events`. Returns whether it found changes, or nil
    /// when it failed or was cancelled.
    func reportingErrors(_ pass: () async throws -> Bool) async -> Bool? {
        continuation.yield(.syncStarted)
        do {
            let changed = try await pass()
            continuation.yield(.syncFinished(now()))
            return changed
        } catch is CancellationError {
            return nil
        } catch {
            continuation.yield(.syncFailed(Self.message(for: error)))
            return nil
        }
    }

    // MARK: Passes

    /// Returns whether the pass found changes: history records, or a full sync.
    private func runPass() async throws -> Bool {
        let passStart = now()
        let accountID = accountID
        let state = try await cache.read { tx in try tx.syncState(accountID: accountID) }
        let changed: Bool
        if let state, let found = try await incrementalSync(from: state.historyID, passStart: passStart) {
            changed = found
        } else {
            try await fullSync(reset: state != nil)
            changed = true
        }
        try await releaseExpiredHolds()
        try await retryPendingReadReceipts()
        // Historical attachment scans compete with the first mail download.
        // Start them only after a usable baseline has committed.
        if hasStarted, indexesAttachmentsAutomatically, !isStopped, !Task.isCancelled {
            startAttachmentIndexing()
        }
        return changed
    }

    /// Lists INBOX, the last 30 days and every draft and stores their metadata,
    /// then deletes cached messages the listings did not return. That covers
    /// both an expired cursor (`reset`) and a first sync that quit partway through.
    private func fullSync(reset: Bool) async throws {
        let passStart = now()
        let labelGeneration = labelRefreshGeneration
        let accountID = accountID
        let deleted = deletedMessageIDs
        let profile = try await gmail.profile()
        guard let historyID = Int64(profile.historyId), historyID > 0 else { throw SyncError.invalidHistoryID }
        let countedAt = now()
        let labels = try await fetchLabels()
        if !reset {
            try await write { tx in try tx.replaceLabels(labels, accountID: accountID, countedAt: countedAt) }
        }

        let inbox = try await listMessageIDs(labelIDs: [SystemLabel.inbox], query: nil, includeSpamTrash: false, limit: Self.inboxCap)
        let recent = try await listMessageIDs(labelIDs: [], query: Self.recentQuery, includeSpamTrash: true)
        // Older drafts stay cached, so the Drafts label is complete.
        let drafts = try await listDrafts()
        let listed = (inbox + recent + drafts.map(\.messageID)).removingDuplicates()
        // Messages pending actions target and messages in held conversations
        // stay cached even when unlisted. Refetch them as well: their stored
        // labels may predate changes the lost history held, and a 404 means
        // Gmail deleted the message.
        let (targeted, held) = try await cache.read { tx in
            (try tx.messageIDsTargetedByPendingActions(accountID: accountID), try tx.messageIDsInHeldThreads(accountID: accountID))
        }
        var wanted = listed + targeted.union(held).subtracting(listed).sorted()

        var gone = Set<String>()
        var fetchedIDs = Set<String>()
        var updates: [CacheTransaction.MessageUpdate] = []
        let kept = Set(listed)
        while true {
            for start in stride(from: 0, to: wanted.count, by: Self.fullSyncChunk) {
                let chunk = Array(wanted[start..<min(start + Self.fullSyncChunk, wanted.count)])
                let (fetched, missing) = try await fetchMetadata(chunk)
                updates += fetched
                fetchedIDs.formUnion(chunk)
                gone.formUnion(missing)
                if !reset {
                    try await write { tx in
                        let live = deleted.withLock { ids in fetched.filter { !ids.contains($0.record.id) } }
                        let threads = try tx.upsertMessages(live)
                        try tx.rebuildThreads(threads, accountID: accountID)
                    }
                }
            }
            let finishedAt = now()
            let remaining = try await write { [gone, fetchedIDs, updates] tx -> Set<String> in
                // Recheck inside the committing transaction. User actions and
                // thread loads can have added protected targets while we awaited.
                let remaining = try tx.messageIDsTargetedByPendingActions(accountID: accountID).subtracting(fetchedIDs)
                guard remaining.isEmpty else { return remaining }
                try tx.replaceLabels(labels, accountID: accountID, countedAt: countedAt)
                try tx.replaceDrafts(drafts, accountID: accountID)
                deleted.withLock { $0.formUnion(gone) }
                let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
                var threads = try tx.upsertMessages(live)
                try tx.deleteAnalyticsMessages(messageIDs: Array(gone), accountID: accountID)
                if reset { try tx.invalidateAnalyticsCoverage(accountID: accountID) }
                threads.formUnion(try tx.deleteMessages(ids: gone, accountID: accountID))
                threads.formUnion(try tx.deleteMessages(notIn: kept, accountID: accountID, through: historyID))
                try tx.dropSentActions(confirmedThrough: historyID, passStart: passStart, accountID: accountID)
                try tx.rebuildThreads(threads, accountID: accountID)
                try tx.saveCursor(historyID: historyID, accountID: accountID, fullSyncAt: finishedAt, reset: reset)
                return []
            }
            guard !remaining.isEmpty else {
                if labelRefreshGeneration == labelGeneration { labelsRefreshedAt = passStart }
                await publishMailNotification(from: nil, to: historyID)
                return
            }
            wanted = remaining.sorted()
        }
    }

    /// Applies `history.list` from `cursor`, committing each page as it
    /// arrives so a long backlog shows up while it downloads. Returns nil when
    /// Gmail no longer has history that old, otherwise whether anything changed.
    private func incrementalSync(from cursor: Int64, passStart: Date) async throws -> Bool? {
        let accountID = accountID
        let deleted = deletedMessageIDs
        var committed = cursor
        var touchedLabels = Set<String>()
        var sawRecords = false
        var pageToken: String?
        repeat {
            let page: HistoryPage
            do {
                page = try await gmail.history(startHistoryID: String(cursor), pageToken: pageToken)
            } catch GmailError.notFound {
                return nil
            }
            guard let pageHistoryID = Int64(page.historyId), pageHistoryID > 0, pageHistoryID >= cursor else {
                throw SyncError.invalidHistoryID
            }
            pageToken = page.nextPageToken
            let isLast = pageToken == nil
            let records = page.history ?? []
            sawRecords = sawRecords || !records.isEmpty
            let cached = try await cache.read { tx in try tx.cachedMessageIDs(accountID: accountID) }
            let changes = try HistoryChanges(records: records, cachedMessageIDs: cached)
            // Gmail stamps every page with the mailbox's current history ID,
            // so only the last page may move the cursor there. An earlier
            // page moves it to its newest record; one without records has
            // nothing to commit.
            let pageCursor: Int64? = isLast ? max(committed, pageHistoryID) : changes.newestHistoryID.map { max(committed, $0) }
            guard let pageCursor else { continue }
            let (fetched, missing) = try await fetchMetadata(changes.messagesToFetch)
            let gone = changes.deletedIDs.union(missing)
            let affected = gone.union(changes.labelChanges.map(\.messageID))

            let touched = try await write { tx -> Set<String> in
                // Counts move for every label an affected message carries:
                // reading a message changes its Inbox count, not just UNREAD's.
                var touched = try tx.labelIDs(ofMessages: affected, accountID: accountID)
                touched.formUnion(changes.labelChanges.flatMap { $0.added + $0.removed })
                touched.formUnion(fetched.flatMap(\.labelIDs))
                deleted.withLock { $0.formUnion(gone) }
                var threads = Set<String>()
                for change in changes.labelChanges {
                    if let threadID = try tx.applyLabelChange(
                        messageID: change.messageID, added: change.added, removed: change.removed,
                        historyID: change.historyID, accountID: accountID
                    ) {
                        threads.insert(threadID)
                    }
                }
                try tx.deleteAnalyticsMessages(messageIDs: Array(gone), accountID: accountID)
                threads.formUnion(try tx.deleteMessages(ids: gone, accountID: accountID))
                let live = deleted.withLock { ids in fetched.filter { !ids.contains($0.record.id) } }
                threads.formUnion(try tx.upsertMessages(live))
                // Store the cursor even when nothing changed, so the next pass starts later.
                try tx.saveCursor(historyID: pageCursor, accountID: accountID)
                // A sent change leaves the overlay once the cursor reaches the
                // history ID Gmail confirmed it at, which is when its own record
                // of the change is in the cache. One confirmed at no history ID
                // waits for a pass that started after its send; `history.list`
                // can lag the write's response by a moment, so a pass that saw
                // nothing new keeps it in view.
                if isLast, pageCursor > cursor {
                    try tx.dropSentActions(confirmedThrough: pageCursor, passStart: passStart, accountID: accountID)
                }
                try tx.rebuildThreads(threads, accountID: accountID)
                return touched
            }
            touchedLabels.formUnion(touched)
            await publishMailNotification(from: committed, to: pageCursor, added: MailSyncNotification.addedMessageHistory(records))
            committed = pageCursor
        } while pageToken != nil

        try await refreshLabels(touched: touchedLabels, passStart: passStart)
        return sawRecords
    }

    /// Brings the labels up to date once the pass has committed its mail:
    /// all of them when the listing is older than `labelRefreshInterval`,
    /// otherwise only the counts of the labels the pass touched. A failure
    /// leaves the mail committed and makes the next pass list everything.
    /// The counts hold every change Gmail accepted before they were asked
    /// for, so those changes' unread deltas go with the write.
    private func refreshLabels(touched: Set<String>, passStart: Date) async throws {
        let accountID = accountID
        let countedAt = now()
        let labelGeneration = labelRefreshGeneration
        do {
            if let refreshedAt = labelsRefreshedAt, passStart.timeIntervalSince(refreshedAt) < Self.labelRefreshInterval {
                guard !touched.isEmpty else { return }
                let labels = try await fetchLabels(ids: touched.sorted())
                try await write { tx in try tx.saveLabels(labels, accountID: accountID, countedAt: countedAt) }
            } else {
                let labels = try await fetchLabels()
                try await write { tx in try tx.replaceLabels(labels, accountID: accountID, countedAt: countedAt) }
                if labelRefreshGeneration == labelGeneration { labelsRefreshedAt = passStart }
            }
        } catch {
            invalidateLabels()
            throw error
        }
    }

    /// A complete label snapshot: `labels.list` names them, `labels.get` adds counts.
    private func fetchLabels() async throws -> [LabelRecord] {
        try await fetchLabels(ids: try await gmail.labels().map(\.id))
    }

    /// `labels.get` for `ids`. A label deleted since is left out.
    private func fetchLabels(ids: [String]) async throws -> [LabelRecord] {
        let accountID = accountID
        let detailed = try await gmail.labels(ids: ids)
        return try ids.compactMap { id in
            switch detailed[id] {
            case .success(let full)?:
                guard full.id == id else { throw GmailError.decoding("Label identity") }
                return Mapping.label(full, accountID: accountID)
            case .failure(.notFound)?:
                return nil
            case .failure(let error)?:
                throw error
            case nil:
                throw GmailError.missingBatchPart
            }
        }
    }

    private func listMessageIDs(labelIDs: [String], query: String?, includeSpamTrash: Bool, limit: Int? = nil) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            let page = try await gmail.listMessages(
                query: query,
                labelIDs: labelIDs,
                includeSpamTrash: includeSpamTrash,
                pageToken: pageToken,
                maxResults: 500
            )
            ids += (page.messages ?? []).map(\.id)
            pageToken = page.nextPageToken
        } while pageToken != nil && (limit.map { ids.count < $0 } ?? true)
        return limit.map { Array(ids.prefix($0)) } ?? ids
    }

    /// Every Gmail draft, with the message it holds.
    func listDrafts() async throws -> [DraftRecord] {
        var drafts: [DraftRecord] = []
        var pageToken: String?
        repeat {
            let page = try await gmail.drafts(query: nil, pageToken: pageToken, maxResults: 500)
            for draft in page.drafts ?? [] {
                guard let message = draft.message else { throw GmailError.decoding("Draft message") }
                drafts.append(DraftRecord(accountID: accountID, id: draft.id, messageID: message.id, threadID: message.threadId))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return drafts
    }

    /// Relists Gmail's drafts, so a draft made in another app can be opened.
    public func refreshDrafts() async throws {
        if isStopped || Task.isCancelled { throw CancellationError() }
        let drafts = try await listDrafts()
        let accountID = accountID
        try await write { tx in try tx.replaceDrafts(drafts, accountID: accountID) }
    }

    /// Metadata for `ids`, plus the IDs Gmail no longer has. Any other failed
    /// part fails the pass.
    func fetchMetadata(
        _ ids: [String]
    ) async throws -> (updates: [CacheTransaction.MessageUpdate], missing: Set<String>) {
        guard !ids.isEmpty else { return ([], []) }
        let results = try await gmail.messages(ids: ids, format: .metadata, metadataHeaders: Self.metadataHeaders)
        var updates: [CacheTransaction.MessageUpdate] = []
        var missing = Set<String>()
        var receiptCandidates: [GmailMessage] = []
        for id in ids {
            switch results[id] {
            case .success(let message)?:
                guard message.id == id else { throw GmailError.decoding("Message identity") }
                updates.append(try Mapping.message(message, accountID: accountID))
                receiptCandidates.append(message)
            case .failure(.notFound)?:
                missing.insert(id)
            case nil:
                throw GmailError.missingBatchPart
            case .failure(let error)?:
                throw error
            }
        }
        try await ingestReadReceiptMetadata(receiptCandidates)
        return (updates, missing)
    }

    // MARK: Opening a thread

    /// Fetches bodies the cache lacks for a thread the user opened, and marks
    /// the thread read.
    public func openThread(_ threadID: String, markRead: Bool = true) async throws {
        if isStopped || Task.isCancelled { throw CancellationError() }
        let accountID = accountID
        let openedAt = now()
        try await write { tx in
            try tx.markThreadOpened(threadID: threadID, accountID: accountID, at: openedAt)
            if markRead, try tx.thread(id: threadID, accountID: accountID)?.isUnread == true {
                _ = try tx.enqueue(
                    .modifyThreads, accountID: accountID, threadIDs: [threadID],
                    remove: [SystemLabel.unread], now: openedAt, notBefore: openedAt
                )
            }
        }
        scheduleSending()
        try await loadReadingThread(threadID, enrichCached: false, foreground: true)
    }

    // MARK: Messages

    /// User-facing text for a failure. Never includes message content or addresses.
    static func message(for error: any Error) -> String {
        switch error as? GmailError {
        case .transport?:
            "Tern can't reach Gmail. Check your internet connection."
        case .rateLimited?:
            "Gmail asked Tern to slow down. It will try again shortly."
        case .server?, .missingBatchPart?:
            "Gmail had a problem. Tern will try again."
        case .unauthorized?:
            "Gmail didn't accept your sign-in."
        default:
            (error as? LocalizedError)?.errorDescription ?? "Tern couldn't sync with Gmail."
        }
    }
}

/// What one run of history records asks the cache to do.
struct HistoryChanges {
    struct LabelChange: Equatable {
        let messageID: String
        let added: [String]
        let removed: [String]
        /// The history record's ID, which becomes the message's stored history ID.
        let historyID: Int64
    }

    /// New messages, and messages with label changes that the cache lacks.
    let messagesToFetch: [String]
    let deletedIDs: Set<String>
    /// Changes to cached messages, in history order. Messages being fetched
    /// are left out, since their fresh metadata already has the final labels.
    let labelChanges: [LabelChange]
    /// The newest record's ID; nil for a page without records.
    let newestHistoryID: Int64?

    init(records: [HistoryRecord], cachedMessageIDs: Set<String>) throws {
        let deleted = Set(records.flatMap { $0.messagesDeleted ?? [] }.map(\.message.id))
        var fetch: [String] = []
        for record in records {
            fetch += (record.messagesAdded ?? []).map(\.message.id)
            let changed = (record.labelsAdded ?? []) + (record.labelsRemoved ?? [])
            fetch += changed.map(\.message.id).filter { !cachedMessageIDs.contains($0) }
        }
        let toFetch = fetch.filter { !deleted.contains($0) }.removingDuplicates()
        let skipped = deleted.union(toFetch)

        var changes: [LabelChange] = []
        var newest: Int64?
        for record in records {
            guard let historyID = Int64(record.id), historyID > 0 else { throw SyncError.invalidHistoryID }
            newest = max(newest ?? 0, historyID)
            for change in record.labelsAdded ?? [] {
                changes.append(LabelChange(
                    messageID: change.message.id, added: change.labelIds, removed: [], historyID: historyID
                ))
            }
            for change in record.labelsRemoved ?? [] {
                changes.append(LabelChange(
                    messageID: change.message.id, added: [], removed: change.labelIds, historyID: historyID
                ))
            }
        }
        messagesToFetch = toFetch
        deletedIDs = deleted
        labelChanges = changes.filter { cachedMessageIDs.contains($0.messageID) && !skipped.contains($0.messageID) }
        newestHistoryID = newest
    }
}
