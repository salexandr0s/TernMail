import Foundation
import GmailAPI
import MailStore
import os

public enum MailAction: Sendable, Equatable {
    case archive
    case trash
    case markRead
    case markUnread
    case star
    case unstar
}

/// One user command can affect several threads. Each target has its own
/// durable queue row, while undo still treats the command as one operation.
public final class ActionReceipt: Sendable, Equatable {
    // The engine enriches rows before sending; UI undo can read them safely
    // after history has removed the durable rows. All access holds this lock.
    private let rows: OSAllocatedUnfairLock<[PendingAction]>
    public var actions: [PendingAction] { rows.withLock { $0 } }
    /// For a snooze, what its undo puts back. Nil for other commands.
    let snooze: SnoozeChange?
    let messageSnooze: MessageSnoozeChange?

    init(actions: [PendingAction], snooze: SnoozeChange? = nil, messageSnooze: MessageSnoozeChange? = nil) {
        rows = OSAllocatedUnfairLock(initialState: actions)
        self.snooze = snooze
        self.messageSnooze = messageSnooze
    }

    func update(_ action: PendingAction) {
        rows.withLock { rows in
            if let index = rows.firstIndex(where: { $0.id == action.id }) { rows[index] = action }
        }
    }

    public static func == (lhs: ActionReceipt, rhs: ActionReceipt) -> Bool { lhs === rhs }
}

/// The registry is confined to SyncEngine. The UI's bounded undo history owns
/// receipts; the engine's weak references cannot keep expired history alive.
final class WeakActionReceipt {
    weak var value: ActionReceipt?
    init(_ value: ActionReceipt) { self.value = value }
}

/// A drain task asleep on its lane. The generation tells a timer that ran
/// out from a later sleep on the same lane.
struct LaneWaiter {
    let generation: UInt64
    let continuation: CheckedContinuation<Void, Never>
}

extension SyncEngine {
    /// Applies `action` to the cache at once and queues it for Gmail. Keep the
    /// returned receipt to undo it. Nil when nothing would change.
    @discardableResult
    public func perform(_ action: MailAction, threadIDs: [String]) async throws -> ActionReceipt? {
        try await enqueue(action, threadIDs: threadIDs, hold: undoHolds.triage)
    }

    /// Reverts an action. A row Gmail has never seen is deleted. One that may
    /// have reached Gmail gets an inverse built from its recorded diff, which
    /// goes out after any request for the row that is still in flight.
    public func undo(_ receipt: ActionReceipt) async throws {
        let actions = receipt.actions.filter { action in
            action.id.map { !unavailableUndoIDs.contains($0) } ?? false
        }
        let ids = Set(actions.compactMap(\.id))
        guard !ids.isEmpty else { return }
        // Reserve before awaiting so concurrent notice/menu undos cannot duplicate it.
        unavailableUndoIDs.formUnion(ids)
        let accountID = accountID
        let now = now()
        do {
            let dropped = try await write { tx -> [Int64] in
                try actions.flatMap { action in try Self.undo(action, accountID: accountID, now: now, in: tx) }
            }
            unavailableUndoIDs.formUnion(dropped)
        } catch {
            unavailableUndoIDs.subtract(ids)
            throw error
        }
        scheduleSending()
        if let adopted = actions.first(where: { $0.kind == .createLabel && $0.labelChange?.adoptedExisting == true }) {
            continuation.yield(.actionFailed(Self.adoptedLabelNotice(named: adopted.labelChange?.newName)))
        }
    }

    /// Returns the IDs of other rows the undo took out of the queue.
    private static func undo(_ action: PendingAction, accountID: String, now: Date, in tx: CacheTransaction) throws -> [Int64] {
        if action.kind.changesLabel {
            return try undoLabelChange(action, accountID: accountID, now: now, in: tx)
        }
        guard let id = action.id, let stored = try tx.action(id: id) else {
            try Self.enqueueInverse(of: action, accountID: accountID, now: now, in: tx)
            return []
        }
        switch stored.state {
        case .queued:
            try tx.deleteAction(id: id)
            // A failed attempt may still have reached Gmail.
            if stored.attempts > 0 {
                try Self.enqueueInverse(of: stored, accountID: accountID, now: now, in: tx)
            }
        case .sending:
            var row = stored
            row.state = .undone
            try tx.updateAction(row)
            try Self.enqueueInverse(of: stored, accountID: accountID, now: now, in: tx)
        case .sent:
            try Self.enqueueInverse(of: stored, accountID: accountID, now: now, in: tx)
        case .undone, .failed:
            break
        }
        return []
    }

    @discardableResult
    func enqueue(_ action: MailAction, threadIDs: [String], hold: TimeInterval) async throws -> ActionReceipt? {
        guard !threadIDs.isEmpty else { return nil }
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(hold)
        let rows = try await write { tx -> [PendingAction] in
            try threadIDs.removingDuplicates().sorted().compactMap { threadID -> PendingAction? in
                let threadIDs = [threadID]
                func modify(add: [String] = [], remove: [String] = []) throws -> PendingAction? {
                    try tx.enqueue(
                        .modifyThreads, accountID: accountID, threadIDs: threadIDs,
                        add: add, remove: remove, now: now, notBefore: notBefore
                    )
                }
                switch action {
                case .archive:
                    return try modify(remove: [SystemLabel.inbox])
                case .markRead:
                    return try modify(remove: [SystemLabel.unread])
                case .markUnread:
                    return try modify(add: [SystemLabel.unread])
                case .unstar:
                    return try modify(remove: [SystemLabel.starred])
                case .trash:
                    return try tx.enqueue(
                        .trashThreads, accountID: accountID, threadIDs: threadIDs,
                        add: [SystemLabel.trash], now: now, notBefore: notBefore
                    )
                case .star:
                    // Gmail stars a message, not a thread. Star the newest one, as Gmail's own apps do.
                    let newest = try threadIDs.compactMap { try tx.messages(threadID: $0, accountID: accountID).last?.id }
                    return try tx.enqueue(
                        .modifyMessages, accountID: accountID, messageIDs: newest,
                        add: [SystemLabel.starred], now: now, notBefore: notBefore
                    )
                }
            }
        }
        guard !rows.isEmpty else { return nil }
        scheduleSending()
        return register(rows)
    }

    /// One receipt for the rows of one user command, so undo treats them as one.
    func register(_ rows: [PendingAction], snooze: SnoozeChange? = nil, messageSnooze: MessageSnoozeChange? = nil) -> ActionReceipt {
        let receipt = ActionReceipt(actions: rows, snooze: snooze, messageSnooze: messageSnooze)
        undoReceipts = undoReceipts.filter { $0.value.value != nil }
        for row in rows {
            if let id = row.id { undoReceipts[id] = WeakActionReceipt(receipt) }
        }
        return receipt
    }

    /// Queues the reverse of `action` with no hold.
    static func enqueueInverse(of action: PendingAction, accountID: String, now: Date, in tx: CacheTransaction) throws {
        switch action.kind {
        case .deleteMessages:
            return
        case .trashMessages, .untrashMessages:
            let restoringTrash = action.kind == .untrashMessages
            let ids = action.messageIDs.filter { id in
                let diff = action.diff[id]
                return restoringTrash ? diff?.removed.contains(SystemLabel.trash) == true : diff?.added.contains(SystemLabel.trash) == true
            }
            if !ids.isEmpty {
                _ = try tx.enqueue(restoringTrash ? .trashMessages : .untrashMessages,
                    accountID: accountID, messageIDs: ids,
                    add: restoringTrash ? [SystemLabel.trash] : [], remove: restoringTrash ? [] : [SystemLabel.trash],
                    now: now, notBefore: now, compensating: true)
            }
            if !restoringTrash {
                let inbox = action.messageIDs.filter { action.diff[$0]?.removed.contains(SystemLabel.inbox) == true }
                if !inbox.isEmpty {
                    _ = try tx.enqueue(.modifyMessages, accountID: accountID, messageIDs: inbox,
                        add: [SystemLabel.inbox], now: now, notBefore: now, compensating: true)
                }
            }
        case .trashThreads:
            _ = try tx.enqueue(
                .untrashThreads, accountID: accountID, threadIDs: action.threadIDs,
                remove: [SystemLabel.trash], now: now, notBefore: now, compensating: true
            )
            if !action.messageIDs.isEmpty {
                _ = try tx.enqueue(
                    .modifyMessages, accountID: accountID, messageIDs: action.messageIDs,
                    add: [SystemLabel.trash], now: now, notBefore: now, compensating: true
                )
            }
        case .untrashThreads:
            _ = try tx.enqueue(
                .trashThreads, accountID: accountID, threadIDs: action.threadIDs,
                add: [SystemLabel.trash], now: now, notBefore: now, compensating: true
            )
        case .saveDraft, .sendDraft, .discardDraft:
            // Draft rows have no inverse. Undo send cancels the row instead.
            return
        case .createLabel, .updateLabel, .deleteLabel:
            try enqueueLabelInverse(of: action, accountID: accountID, now: now, in: tx)
        case .createFilter, .deleteFilter, .replaceFilter, .updateVacation, .updateSignature:
            try enqueueSettingsInverse(of: action, accountID: accountID, now: now, in: tx)
        case .modifyThreads, .modifyMessages:
            // Restore each message exactly: archiving a thread removed INBOX only
            // from the messages that had it, so only those get it back. A label
            // created since gets Gmail's ID in place of the temporary one.
            let resolve = { (ids: [String]) throws -> [String] in
                try ids.map { try tx.resolvedLabelID($0, accountID: accountID) }
            }
            let groups = Dictionary(grouping: action.diff, by: \.value)
                .map { (diff: $0.key, messageIDs: $0.value.map(\.key).sorted()) }
                .sorted { $0.messageIDs.first ?? "" < $1.messageIDs.first ?? "" }
            for group in groups where !group.diff.added.isEmpty || !group.diff.removed.isEmpty {
                _ = try tx.enqueue(
                    .modifyMessages, accountID: accountID, threadIDs: action.threadIDs, messageIDs: group.messageIDs,
                    add: try resolve(group.diff.removed), remove: try resolve(group.diff.added), now: now, notBefore: now, compensating: true
                )
            }
        }
    }

    // MARK: Sending

    /// Starts a send loop for each lane that isn't running, and wakes the
    /// ones asleep, so a new row or an undo is looked at now.
    func scheduleSending() {
        guard sendsAutomatically, !isStopped else { return }
        let lanes: [PendingAction.Lane] = settings == nil ? [.labels, .compose] : [.labels, .compose, .settings]
        for lane in lanes {
            wakeRequests.insert(lane)
            wake(lane)
            if drainTasks[lane] == nil {
                // The user's own changes go out ahead of sync and background requests.
                drainTasks[lane] = Task {
                    await GmailRequestBudget.$priority.withValue(.interactive) { await drainQueue(lane) }
                }
            }
        }
    }

    /// Sends a lane's due rows until it is empty. Between rows it sleeps until
    /// the next hold or backoff ends, or until `scheduleSending()` wakes it.
    private func drainQueue(_ lane: PendingAction.Lane) async {
        let accountID = accountID
        while !Task.isCancelled, !(lane == .compose && isStoppingDrafts) {
            wakeRequests.remove(lane)
            let dueTimes = try? await cache.read { tx in
                try tx.pendingActions(accountID: accountID)
                    .filter { $0.state == .queued && $0.kind.lane == lane }
                    .map(\.notBefore)
            }
            guard let dueTimes, let next = dueTimes.min() else {
                // A row queued while the read was in flight sets the flag again.
                if wakeRequests.contains(lane) { continue }
                break
            }
            let now = now()
            if next > now {
                await sleepUntilWoken(lane, limit: next.timeIntervalSince(now))
            } else if await sendDue(lane) == 0 {
                // Every due row waits behind an older change to its thread or
                // draft. The next backoff to end may release one.
                let release = dueTimes.filter { $0 > now }.min()
                await sleepUntilWoken(lane, limit: release?.timeIntervalSince(now) ?? 1)
            }
        }
        drainTasks[lane] = nil
    }

    /// Sleeps until `wake(_:)` is called for `lane` or `limit` seconds pass.
    /// Returns at once when a wake request is already pending.
    private func sleepUntilWoken(_ lane: PendingAction.Lane, limit: TimeInterval) async {
        guard limit > 0, !isStopped, !Task.isCancelled, !wakeRequests.contains(lane) else { return }
        laneWaiterGeneration += 1
        let generation = laneWaiterGeneration
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(limit)) } catch { return }
            await self?.wake(lane, generation: generation)
        }
        // Registering and `stop()` both run on the actor without suspending,
        // so a waiter is either resumed by `stop()` or never registered after it.
        await withCheckedContinuation { continuation in
            laneWaiters[lane] = LaneWaiter(generation: generation, continuation: continuation)
        }
        timer.cancel()
    }

    /// Resumes the drain task asleep on `lane`. With a generation, only the
    /// sleep it was set for.
    func wake(_ lane: PendingAction.Lane, generation: UInt64? = nil) {
        guard let waiter = laneWaiters[lane], generation == nil || waiter.generation == generation else { return }
        laneWaiters[lane] = nil
        waiter.continuation.resume()
    }

    private func sendDue(_ lane: PendingAction.Lane) async -> Int {
        switch lane {
        case .labels: await sendDueActions()
        case .compose: await sendDueDrafts()
        case .settings: await sendDueSettings()
        }
    }

    /// Sends every queued row whose hold or backoff has passed and returns how
    /// many it claimed. Label rows go out one at a time; changes to
    /// conversations that match are combined into one request.
    @discardableResult
    public func sendDueActions() async -> Int {
        let accountID = accountID
        let now = now()
        guard let (claimed, due) = try? await write({ tx -> (Int, [PendingAction]) in
            let claimed = try tx.claimDueActions(accountID: accountID, now: now, lane: .labels)
            return (claimed.count, try claimed.compactMap { try Self.resolvingTemporaryLabels($0, accountID: accountID, in: tx) })
        }) else {
            return 0
        }
        for row in due where row.kind.changesLabel { await sendLabelChange(row) }
        let groups = Dictionary(grouping: due.filter { !$0.kind.changesLabel }, by: DeliveryKey.init).values.sorted {
            ($0.first?.id ?? Int64.max) < ($1.first?.id ?? Int64.max)
        }
        for group in groups { await send(group) }
        return claimed
    }

    private struct DeliveryKey: Hashable {
        let kind: String
        let add: [String]
        let remove: [String]
        let labelID: String?

        init(_ row: PendingAction) {
            kind = row.kind.rawValue
            add = row.addLabelIDs.sorted()
            remove = row.removeLabelIDs.sorted()
            labelID = row.kind == .deleteMessages ? row.labelID : nil
        }
    }

    enum Outcome {
        case sent
        case retry(String)
        case failed(String)
    }

    /// A change goes out as recorded: its diff names the messages the user
    /// saw, and undo restores exactly those. Only a message-scoped trash or
    /// untrash of messages the cache has never held fetches their labels
    /// first, so undo can restore them too. Existing diffs survive retries.
    private func prepare(_ action: PendingAction) async throws -> PendingAction? {
        guard action.kind == .trashMessages || action.kind == .untrashMessages, let id = action.id else { return action }
        let unknown = action.messageIDs.filter { action.diff[$0] == nil }
        guard !unknown.isEmpty else { return action }
        var snapshots: [GmailMessage] = []
        let found = try await gmail.messages(ids: unknown, format: .minimal, metadataHeaders: [])
        for messageID in unknown {
            guard let result = found[messageID] else { throw GmailError.missingBatchPart }
            switch result {
            case .success(let message):
                guard message.id == messageID else { throw GmailError.decoding("Message snapshot") }
                snapshots.append(message)
            case .failure(.notFound): continue
            case .failure(let error): throw error
            }
        }
        return try await write { [snapshots] tx in
            guard var row = try tx.action(id: id), row.state == .sending else { return nil }
            for message in snapshots where row.diff[message.id] == nil {
                let labels = Set(message.labelIds ?? [])
                row.diff[message.id] = PendingAction.LabelDiff(
                    added: row.addLabelIDs.filter { !labels.contains($0) }.sorted(),
                    removed: row.removeLabelIDs.filter(labels.contains).sorted()
                )
            }
            try tx.updateAction(row)
            return row
        }
    }

    private func send(_ actions: [PendingAction]) async {
        var ready: [PendingAction] = []
        for action in actions {
            guard !isStopped, !Task.isCancelled, let id = action.id else { return }
            let current = try? await cache.read { tx in try tx.action(id: id) }
            guard let current = current ?? nil, current.state == .sending else {
                _ = try? await write { tx in try tx.deleteActionIfUndone(id: id) }
                continue
            }
            do {
                guard let prepared = try await prepare(current) else {
                    _ = try? await write { tx in try tx.deleteActionIfUndone(id: id) }
                    continue
                }
                undoReceipts[id]?.value?.update(prepared)
                ready.append(prepared)
            } catch {
                await finish(current, outcome: Self.outcome(for: error))
            }
        }
        guard var combined = ready.first, !isStopped, !Task.isCancelled else { return }
        combined.threadIDs = ready.flatMap(\.threadIDs).removingDuplicates().sorted()
        combined.messageIDs = ready.flatMap(\.messageIDs).removingDuplicates().sorted()
        do {
            let result = try await deliver(combined)
            for action in ready {
                let ids = Set(action.threadIDs + action.messageIDs)
                let errors = result.failures.filter { ids.contains($0.key) }.map(\.value).filter { $0 != .notFound }
                let outcome: Outcome
                if errors.isEmpty { outcome = .sent }
                else if errors.allSatisfy(Self.shouldRetry) { outcome = .retry(String(describing: errors[0])) }
                else { outcome = .failed(String(describing: errors[0])) }
                await finish(action, outcome: outcome, confirmedHistoryID: result.confirmedHistoryID)
            }
        } catch {
            for action in ready { await finish(action, outcome: Self.outcome(for: error)) }
        }
    }

    static func outcome(for error: any Error) -> Outcome {
        if let error = error as? GmailError {
            return shouldRetry(error) ? .retry(String(describing: error)) : .failed(String(describing: error))
        }
        return .retry(String(describing: type(of: error)))
    }

    static func shouldRetry(_ error: GmailError) -> Bool {
        // An unreadable response does not establish that Gmail rejected the
        // mutation. Keep intent and undo just as for a lost network response.
        switch error {
        case .decoding, .unauthorized: true
        default: error.isRetryable
        }
    }

    /// `confirmedHistoryID` is where Gmail said its history stood after a sent
    /// change; the pass that reaches it drops the row.
    func finish(_ current: PendingAction, outcome: Outcome, confirmedHistoryID: Int64? = nil) async {
        guard let id = current.id else { return }
        var row = current
        let now = now()
        switch outcome {
        case .sent:
            row.state = .sent
            row.sentAt = now
            row.lastError = nil
            row.confirmedHistoryID = confirmedHistoryID
        case .retry(let reason):
            row.state = .queued
            row.lastError = reason
            row.notBefore = now.addingTimeInterval(min(pow(2, Double(row.attempts)), 300))
        case .failed(let message):
            row.state = .failed
            row.lastError = message
        }
        let failed = if case .failed = outcome { true } else { false }
        // Undone during the request: its inverse is queued behind it, so the row
        // just goes, whatever Gmail answered.
        let reported = try? await write { [row] tx -> Bool in
            if try tx.deleteActionIfUndone(id: id) { return false }
            if failed {
                try tx.retainFailedAction(row, message: row.lastError ?? "Gmail refused this change.")
            } else {
                try tx.updateAction(row)
            }
            return failed
        }
        if reported == true {
            unavailableUndoIDs.insert(id)
            continuation.yield(.actionFailed("Gmail didn't accept this change. The conversation was restored."))
        }
        // Gmail's own record of the change, and whatever it did alongside
        // (a filter, a merged conversation), comes in with the next pass. A
        // label that was renamed or recolored is listed again in full. A
        // sent or saved draft is fetched by the compose lane itself.
        if case .sent = outcome {
            if current.kind.changesLabel { labelsRefreshedAt = nil }
            if sendsAutomatically, current.kind.lane != .compose { requestSync(reason: .afterAction) }
        }
    }

    private func deliver(_ action: PendingAction) async throws -> LabelChangeResult {
        switch action.kind {
        case .modifyThreads:
            return try await gmail.modifyThreads(
                ids: action.threadIDs, addLabelIDs: action.addLabelIDs, removeLabelIDs: action.removeLabelIDs
            )
        case .trashThreads:
            return try await gmail.trashThreads(ids: action.threadIDs)
        case .untrashThreads:
            return try await gmail.untrashThreads(ids: action.threadIDs)
        case .trashMessages:
            guard let triage else { throw GmailError.invalidRequest("Message trash unavailable") }
            return LabelChangeResult(failures: try await triage.trashMessages(ids: action.messageIDs))
        case .untrashMessages:
            guard let triage else { throw GmailError.invalidRequest("Message trash unavailable") }
            return LabelChangeResult(failures: try await triage.untrashMessages(ids: action.messageIDs))
        case .deleteMessages:
            try await deliverPermanentDeletion(action)
            return LabelChangeResult()
        case .modifyMessages:
            guard !action.messageIDs.isEmpty else { return LabelChangeResult() }
            return try await gmail.batchModifyMessages(
                ids: action.messageIDs, addLabelIDs: action.addLabelIDs, removeLabelIDs: action.removeLabelIDs
            )
        case .saveDraft, .sendDraft, .discardDraft:
            // Claimed only by the compose lane, never batched with label changes.
            return LabelChangeResult()
        case .createLabel, .updateLabel, .deleteLabel:
            // Sent one at a time by `sendLabelChange(_:)`.
            return LabelChangeResult()
        case .createFilter, .deleteFilter, .replaceFilter, .updateVacation, .updateSignature:
            // Claimed only by the settings lane.
            return LabelChangeResult()
        }
    }
}
