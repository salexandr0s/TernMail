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

    private var timer: Task<Void, Never>?
    private var checking: Task<Void, Never>?
    private var checksAgain = false
    private var isStopped = false

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
    }

    /// Archives conversations until `wakeAt`. Keep the receipt for `undoSnooze`.
    public func snooze(threadIDs: [String], until wakeAt: Date) async throws -> ActionReceipt? {
        guard !isStopped else { throw CancellationError() }
        guard let receipt = try await engine.snooze(threadIDs: threadIDs, until: wakeAt) else { return nil }
        let createdAt = engine.now()
        for threadID in Set(threadIDs) {
            try await accounts.saveSnooze(
                SnoozeRecord(accountID: engine.accountID, threadID: threadID, wakeAt: wakeAt, createdAt: createdAt)
            )
        }
        scheduleNextCheck()
        return receipt
    }

    /// Takes back a snooze: the archive, the hold and the record.
    public func undoSnooze(_ receipt: ActionReceipt) async throws {
        let threadIDs = Set(receipt.actions.flatMap(\.threadIDs))
        try await engine.undo(receipt)
        try await engine.releaseSnoozes(threadIDs)
        try await deleteRecords(threadIDs)
        scheduleNextCheck()
    }

    /// Brings snoozed conversations back to the Inbox now.
    public func unsnooze(threadIDs: [String]) async throws {
        let now = engine.now()
        try await engine.wake(Dictionary(threadIDs.map { ($0, now) }, uniquingKeysWith: { first, _ in first }))
        try await deleteRecords(Set(threadIDs))
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
        let task = Task { await runChecks() }
        checking = task
        await task.value
        checking = nil
        scheduleNextCheck()
    }

    private func runChecks() async {
        repeat {
            checksAgain = false
            await checkOnce()
        } while checksAgain && !isStopped
    }

    private func checkOnce() async {
        // A failed step leaves everything for the next check.
        do {
            try await reconcile()
            let now = engine.now()
            var ended = Set<String>()
            var due: [String: Date] = [:]
            for state in try await engine.snoozeStates() {
                if !state.isCached {
                    // Gone only on Gmail's word, never because the cache lacks it.
                    if try await !engine.fetchSnoozed(state.threadID, until: state.wakeAt) { ended.insert(state.threadID) }
                } else if state.wakeAt <= now {
                    due[state.threadID] = state.wakeAt
                } else if state.isInInbox {
                    // New mail, or moved back in Tern or in Gmail.
                    ended.insert(state.threadID)
                }
            }
            if !due.isEmpty {
                try await engine.wake(due)
                try await deleteRecords(Set(due.keys))
            }
            if !ended.isEmpty {
                try await engine.releaseSnoozes(ended)
                try await deleteRecords(ended)
            }
        } catch {
            return
        }
    }

    /// Gives a hold without a record its record, after a crash between the
    /// writes, and holds again the conversation of a record without a hold,
    /// after a cache reset or a crash before the record was deleted.
    private func reconcile() async throws {
        let accountID = engine.accountID
        let records = try await accounts.snoozes(accountID: accountID)
        let holds = try await engine.snoozeHolds()
        let recorded = Set(records.map(\.threadID))
        let now = engine.now()
        for (threadID, wakeAt) in holds where !recorded.contains(threadID) {
            try await accounts.saveSnooze(SnoozeRecord(accountID: accountID, threadID: threadID, wakeAt: wakeAt, createdAt: now))
        }
        for record in records where holds[record.threadID] == nil {
            if try await !engine.fetchSnoozed(record.threadID, until: record.wakeAt) {
                try await accounts.deleteSnooze(accountID: accountID, threadID: record.threadID)
            }
        }
    }

    private func deleteRecords(_ threadIDs: Set<String>) async throws {
        for threadID in threadIDs.sorted() {
            try await accounts.deleteSnooze(accountID: engine.accountID, threadID: threadID)
        }
    }

    /// Checks again at the next wake time, or in a minute when a wake is
    /// overdue because the last check couldn't finish it.
    private func scheduleNextCheck() {
        guard schedulesChecks, !isStopped else { return }
        timer?.cancel()
        timer = Task { [weak self, engine] in
            guard let next = try? await engine.snoozeHolds().values.min() else { return }
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

extension SyncEngine {
    /// Archives conversations and holds them until `wakeAt` in one write.
    func snooze(threadIDs: [String], until wakeAt: Date) async throws -> ActionReceipt? {
        let threadIDs = threadIDs.removingDuplicates().sorted()
        guard !threadIDs.isEmpty else { return nil }
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let rows = try await write { tx in
            try threadIDs.map { threadID in
                let row = try tx.enqueue(
                    .modifyThreads, accountID: accountID, threadIDs: [threadID],
                    remove: [SystemLabel.inbox], now: now, notBefore: notBefore
                )
                try tx.holdSnooze(threadID: threadID, until: wakeAt, accountID: accountID)
                return row
            }
        }
        scheduleSending()
        return register(rows)
    }

    /// Brings conversations back to the Inbox, each sorted by its wake time,
    /// and ends their snoozes in one write. Messages in Trash or Spam stay
    /// there, so a conversation trashed while snoozed stays in Trash.
    func wake(_ wakes: [String: Date]) async throws {
        let accountID = accountID
        let now = now()
        try await write { tx in
            for (threadID, wokeAt) in wakes.sorted(by: { $0.key < $1.key }) {
                let outside = try tx.currentLabels(threadID: threadID, accountID: accountID)
                    .filter { !$0.value.contains(SystemLabel.trash) && !$0.value.contains(SystemLabel.spam) }
                    .keys.sorted()
                if !outside.isEmpty {
                    _ = try tx.enqueue(
                        .modifyMessages, accountID: accountID, threadIDs: [threadID], messageIDs: outside,
                        add: [SystemLabel.inbox], now: now, notBefore: now
                    )
                    try tx.recordWake(threadID: threadID, at: wokeAt, accountID: accountID)
                }
                try tx.releaseSnooze(threadID: threadID, accountID: accountID)
            }
        }
        scheduleSending()
    }

    /// Ends snoozes in the cache and leaves the conversations where they are.
    func releaseSnoozes(_ threadIDs: Set<String>) async throws {
        let accountID = accountID
        try await write { tx in
            for threadID in threadIDs.sorted() {
                try tx.releaseSnooze(threadID: threadID, accountID: accountID)
            }
        }
    }

    func snoozeHolds() async throws -> [String: Date] {
        let accountID = accountID
        return try await cache.read { tx in try tx.snoozeHolds(accountID: accountID) }
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

    /// Fetches a snoozed conversation and holds it again, in one write. False
    /// when Gmail no longer has it.
    func fetchSnoozed(_ threadID: String, until wakeAt: Date) async throws -> Bool {
        let (updates, missing) = try await fetchThreadMetadata([threadID])
        guard !missing.contains(threadID) else { return false }
        let accountID = accountID
        let deleted = deletedMessageIDs
        try await write { [updates] tx in
            let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
            try tx.rebuildThreads(try tx.upsertMessages(live), accountID: accountID)
            try tx.holdSnooze(threadID: threadID, until: wakeAt, accountID: accountID)
        }
        return true
    }
}
