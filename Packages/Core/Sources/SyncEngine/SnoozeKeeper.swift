import Foundation
import GmailAPI
import MailStore

/// Wakes one account's snoozed conversations. It checks at launch, at the
/// next wake time, and when the app asks: after each sync pass and when the
/// Mac wakes. Tern can't wake anything while it isn't running, so overdue
/// snoozes wake at launch.
///
/// The cache's snooze hold is the working copy of a snooze and the record
/// in `config.sqlite` the durable one. Every change writes the cache first,
/// so a crash between the two writes leaves a step that's safe to repeat.
public actor SnoozeKeeper {
    let engine: SyncEngine
    let accounts: AccountStore
    /// Tests turn this off and call `check()` themselves.
    let schedulesChecks: Bool
    let operations = SnoozeOperationGate()

    private var timer: Task<Void, Never>?
    private var checking: Task<Void, Never>?
    private var checksAgain = false
    var isStopped = false

    public init(engine: SyncEngine, accounts: AccountStore, schedulesChecks: Bool = true) {
        self.engine = engine
        self.accounts = accounts
        self.schedulesChecks = schedulesChecks
    }

    /// Records snoozes the config lacks, holds again conversations a cache
    /// reset dropped, and wakes what is due.
    public func start() async {
        await check()
    }

    /// Stops checking and waits for a check under way.
    public func stop() async {
        isStopped = true
        timer?.cancel()
        timer = nil
        await checking?.value
        await operations.perform {}
    }

    /// Archives conversations until `wakeAt`. Keep the receipt for `undoSnooze`.
    public func snooze(threadIDs: [String], until wakeAt: Date) async throws -> ActionReceipt? {
        try await operations.perform { [self] in
            try await snoozeThreads(threadIDs, until: wakeAt)
        }
    }

    private func snoozeThreads(_ threadIDs: [String], until wakeAt: Date) async throws -> ActionReceipt? {
        guard !isStopped else { throw CancellationError() }
        guard let receipt = try await engine.snooze(threadIDs: threadIDs, until: wakeAt) else { return nil }
        let records = (receipt.snooze?.threadIDs ?? []).map {
            SnoozeRecord(accountID: engine.accountID, threadID: $0, wakeAt: wakeAt, createdAt: engine.now())
        }
        try await accounts.applyThreadSnoozes(records, removingMessages: receipt.snooze?.replacedMessages ?? [], accountID: engine.accountID)
        scheduleNextCheck()
        return receipt
    }

    /// Takes back a snooze without changing a newer independent schedule.
    public func undoSnooze(_ receipt: ActionReceipt) async throws {
        try await operations.perform { [self] in try await undoSnoozeContents(receipt) }
    }

    private func undoSnoozeContents(_ receipt: ActionReceipt) async throws {
        guard !isStopped else { throw CancellationError() }
        let undoable: [PendingAction]
        if let change = receipt.messageSnooze {
            let revisions = Dictionary(uniqueKeysWithValues: change.records.map { ($0.messageID, $0.revision) })
            let current = Set(try await engine.messageSnoozeHolds().filter { revisions[$0.messageID] == $0.revision }.map(\.messageID))
            undoable = receipt.actions.filter { !Set($0.messageIDs).isDisjoint(with: current) }
        } else if let change = receipt.snooze {
            let current = try await engine.snoozeHolds(wakingAt: change.wakeAt)
            undoable = receipt.actions.filter { $0.threadIDs.contains { current[$0] != nil } }
        } else { undoable = receipt.actions }
        try await engine.undo(ActionReceipt(actions: undoable))
        if let change = receipt.messageSnooze {
            let undone = try await engine.undoMessageSnoozeHolds(change)
            try await accounts.applySnoozeChanges(messages: undone.restored, removingMessages: undone.released, accountID: engine.accountID)
        } else if let snooze = receipt.snooze {
            let undone = try await engine.undoSnoozeHolds(snooze)
            let restored = try await engine.restoreReplacedMessageSnoozes(snooze.replacedMessages.filter { undone.released.contains($0.threadID) })
            let threads = undone.restored.map { SnoozeRecord(accountID: engine.accountID, threadID: $0.key, wakeAt: $0.value, createdAt: engine.now()) }
            try await accounts.applySnoozeChanges(threads: threads, messages: restored,
                removingThreads: Dictionary(uniqueKeysWithValues: undone.released.map { ($0, snooze.wakeAt) }), accountID: engine.accountID)
        }
        scheduleNextCheck()
    }

    /// Brings snoozed conversations back to the Inbox now.
    public func unsnooze(threadIDs: [String]) async throws {
        try await operations.perform { [self] in try await unsnoozeThreads(threadIDs) }
    }

    private func unsnoozeThreads(_ threadIDs: [String]) async throws {
        guard !isStopped else { throw CancellationError() }
        let now = engine.now()
        let messages = try await engine.messageSnoozeHolds().filter { threadIDs.contains($0.threadID) }
        try await engine.wake(Dictionary(threadIDs.map { ($0, now) }, uniquingKeysWith: { first, _ in first }))
        try await deleteRecords(Set(threadIDs))
        try await accounts.deleteMessageSnoozes(messages, accountID: engine.accountID)
        scheduleNextCheck()
    }

    /// Wakes what is due and ends snoozes whose conversation is back in the
    /// Inbox or gone. A call during a check runs one more after it.
    public func check() async {
        guard !isStopped else { return }
        if let checking {
            checksAgain = true
            await checking.value
            return
        }
        let task = Task {
            await runChecks()
            checking = nil
            scheduleNextCheck()
        }
        checking = task
        await task.value
    }

    private func runChecks() async {
        repeat {
            checksAgain = false
            await checkOnce()
        } while checksAgain && !isStopped
    }

    private func checkOnce() async {
        // Network reads run outside the operation gate, so an explicit Snooze
        // can still replace a schedule while a metadata request is waiting.
        do {
            try await reconcileSnoozes()
            try await operations.perform { [self] in try await finishDueSnoozes() }
        } catch { return }
    }

    private func deleteRecords(_ threadIDs: Set<String>) async throws {
        for threadID in threadIDs.sorted() {
            try await accounts.deleteSnooze(accountID: engine.accountID, threadID: threadID)
        }
    }

    /// Checks again at the next wake time, or in a minute when a wake is
    /// overdue because the last check couldn't finish it.
    func scheduleNextCheck() {
        guard schedulesChecks, !isStopped else { return }
        timer?.cancel()
        timer = Task { [weak self, engine] in
            guard let threads = try? await engine.snoozeHolds(),
                  let messages = try? await engine.messageSnoozeHolds(),
                  let next = (Array(threads.values) + messages.map(\.wakeAt)).min() else { return }
            let delay = next.timeIntervalSince(engine.now())
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 60))
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }
}

/// A snoozed conversation as a check sees it.
struct SnoozeState: Sendable {
    let threadID: String
    let wakeAt: Date
    /// Whether the cache has any of its messages.
    let isCached: Bool
    /// In the Inbox, with queued changes applied, so a snooze whose archive
    /// hasn't reached Gmail yet doesn't look ended.
    let isInInbox: Bool
}

/// What a snooze changed, so its undo can put back a snooze it replaced.
struct SnoozeChange: Sendable {
    let threadIDs: [String]
    let wakeAt: Date
    /// Conversations that were snoozed already, with their earlier wake times.
    let replaced: [String: Date]
    let replacedMessages: [MessageSnoozeRecord]
}

extension SyncEngine {
    /// Archives conversations and holds them until `wakeAt` in one write. The
    /// receipt keeps the wake times of the snoozes this one replaces.
    func snooze(threadIDs: [String], until wakeAt: Date) async throws -> ActionReceipt? {
        let threadIDs = threadIDs.removingDuplicates().sorted()
        guard !threadIDs.isEmpty else { return nil }
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHolds.triage)
        let (rows, replaced, replacedMessages) = try await write { tx -> ([PendingAction], [String: Date], [MessageSnoozeRecord]) in
            let earlier = try tx.snoozeHolds(accountID: accountID).filter { threadIDs.contains($0.key) }
            let replacedMessages = try tx.messageSnoozeHolds(accountID: accountID).filter { threadIDs.contains($0.threadID) }
            for record in replacedMessages {
                try tx.releaseMessageSnooze(messageID: record.messageID, wakingAt: record.wakeAt, revision: record.revision, accountID: accountID)
            }
            // A conversation already out of the Inbox gets its hold and no row.
            let rows = try threadIDs.compactMap { threadID -> PendingAction? in
                let row = try tx.enqueue(
                    .modifyThreads, accountID: accountID, threadIDs: [threadID],
                    remove: [SystemLabel.inbox], now: now, notBefore: notBefore
                )
                try tx.holdSnooze(threadID: threadID, until: wakeAt, accountID: accountID)
                return row
            }
            return (rows, earlier, replacedMessages)
        }
        scheduleSending()
        return register(rows, snooze: SnoozeChange(threadIDs: threadIDs, wakeAt: wakeAt, replaced: replaced, replacedMessages: replacedMessages))
    }

    /// Takes back a snooze's holds in one write. A conversation whose hold is
    /// still this snooze's gets back the snooze it replaced while it stays out
    /// of the Inbox, or else no hold. Returns the conversations changed: those
    /// with an earlier snooze back, with its wake time, and those released.
    func undoSnoozeHolds(_ snooze: SnoozeChange) async throws -> (restored: [String: Date], released: Set<String>) {
        let accountID = accountID
        return try await write { tx in
            var restored: [String: Date] = [:]
            var released = Set<String>()
            for threadID in snooze.threadIDs {
                guard try tx.releaseSnooze(threadID: threadID, wakingAt: snooze.wakeAt, accountID: accountID) else { continue }
                let inInbox = try tx.currentLabels(threadID: threadID, accountID: accountID)
                    .values.contains { $0.contains(SystemLabel.inbox) }
                if let earlier = snooze.replaced[threadID], !inInbox {
                    try tx.holdSnooze(threadID: threadID, until: earlier, accountID: accountID)
                    restored[threadID] = earlier
                } else {
                    released.insert(threadID)
                }
            }
            return (restored, released)
        }
    }

    /// Brings conversations back to the Inbox now, each sorted by its wake
    /// time, and ends their snoozes in one write.
    func wake(_ wakes: [String: Date]) async throws {
        let accountID = accountID
        let now = now()
        try await write { tx in
            for record in try tx.messageSnoozeHolds(accountID: accountID) where wakes[record.threadID] != nil {
                try tx.releaseMessageSnooze(messageID: record.messageID, wakingAt: record.wakeAt, revision: record.revision, accountID: accountID)
            }
            for (threadID, wokeAt) in wakes.sorted(by: { $0.key < $1.key }) {
                try Self.bringBack(threadID, wokeAt: wokeAt, accountID: accountID, now: now, in: tx)
                try tx.releaseSnooze(threadID: threadID, accountID: accountID)
            }
        }
        scheduleSending()
    }

    /// Ends the snoozes a check found finished, in one write: `due`
    /// conversations come back to the Inbox, each sorted by its wake time,
    /// and `ended` ones, back in the Inbox already or gone from Gmail, stay
    /// where they are. Values are the wake times the check read. A hold that
    /// changed since was moved or undone, and a conversation that left the
    /// Inbox since stays snoozed, so both wait for the next check. Returns the
    /// snoozes that ended, with their wake times.
    func endSnoozes(waking due: [String: Date], releasing ended: [String: Date]) async throws -> [String: Date] {
        guard !due.isEmpty || !ended.isEmpty else { return [:] }
        let accountID = accountID
        let now = now()
        let finished = try await write { tx -> [String: Date] in
            var finished: [String: Date] = [:]
            for (threadID, wakeAt) in due.sorted(by: { $0.key < $1.key }) {
                guard try tx.releaseSnooze(threadID: threadID, wakingAt: wakeAt, accountID: accountID) else { continue }
                try Self.bringBack(threadID, wokeAt: wakeAt, accountID: accountID, now: now, in: tx)
                finished[threadID] = wakeAt
            }
            for (threadID, wakeAt) in ended.sorted(by: { $0.key < $1.key }) {
                // A conversation Gmail no longer has has no cached messages.
                let labels = try tx.currentLabels(threadID: threadID, accountID: accountID)
                guard labels.isEmpty || labels.values.contains(where: { $0.contains(SystemLabel.inbox) }),
                      try tx.releaseSnooze(threadID: threadID, wakingAt: wakeAt, accountID: accountID)
                else { continue }
                finished[threadID] = wakeAt
            }
            return finished
        }
        scheduleSending()
        return finished
    }

    /// Queues a conversation's way back to the Inbox and sorts it by `wokeAt`.
    /// Messages in Trash or Spam stay there, so a conversation trashed while
    /// snoozed stays in Trash.
    private static func bringBack(_ threadID: String, wokeAt: Date, accountID: String, now: Date, in tx: CacheTransaction) throws {
        let heldMessages = Set(try tx.messageSnoozeHolds(accountID: accountID).map(\.messageID))
        let outside = try tx.currentLabels(threadID: threadID, accountID: accountID)
            .filter { !heldMessages.contains($0.key) && !$0.value.contains(SystemLabel.trash) && !$0.value.contains(SystemLabel.spam) }
            .keys.sorted()
        guard !outside.isEmpty else { return }
        _ = try tx.enqueue(
            .modifyMessages, accountID: accountID, threadIDs: [threadID], messageIDs: outside,
            add: [SystemLabel.inbox], now: now, notBefore: now
        )
        try tx.recordWake(threadID: threadID, at: wokeAt, accountID: accountID)
    }

    func snoozeHolds(wakingAt wakeAt: Date? = nil) async throws -> [String: Date] {
        let accountID = accountID
        return try await cache.read { tx in try tx.snoozeHolds(accountID: accountID, wakingAt: wakeAt) }
    }

    func snoozeStates() async throws -> [SnoozeState] {
        let accountID = accountID
        return try await cache.read { tx in
            try tx.snoozeHolds(accountID: accountID).sorted { $0.key < $1.key }.map { threadID, wakeAt in
                let labels = try tx.currentLabels(threadID: threadID, accountID: accountID)
                return SnoozeState(
                    threadID: threadID, wakeAt: wakeAt, isCached: !labels.isEmpty,
                    isInInbox: labels.values.contains { $0.contains(SystemLabel.inbox) }
                )
            }
        }
    }

    /// Fetches a snoozed conversation and holds it until `wakeAt`, in one
    /// write, unless its hold changed from `held` (nil for none) while the
    /// request was out. False when Gmail no longer has it.
    func fetchSnoozed(_ threadID: String, until wakeAt: Date, ifHeldUntil held: Date?) async throws -> Bool {
        let (updates, missing) = try await fetchThreadMetadata([threadID])
        guard !missing.contains(threadID) else { return false }
        let accountID = accountID
        let deleted = deletedMessageIDs
        try await write { [updates] tx in
            let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
            try tx.rebuildThreads(try tx.upsertMessages(live), accountID: accountID)
            // `held` was read from the cache, so an unchanged hold compares equal.
            if try tx.snoozeHolds(accountID: accountID)[threadID] == held {
                try tx.holdSnooze(threadID: threadID, until: wakeAt, accountID: accountID)
            }
        }
        return true
    }
}
