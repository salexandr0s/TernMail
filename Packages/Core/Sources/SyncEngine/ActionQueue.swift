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

    /// Sends what waited for the account to sign in again at once, along with
    /// every change waiting out a backoff after a failed try. The app calls
    /// this after sign-in; a pass that reaches Gmail calls it too while the
    /// queue waits.
    public func resumeAfterSignIn() async {
        guard !isStopped else { return }
        waitsForSignIn = false
        let accountID = accountID
        let now = now()
        _ = try? await write { tx in try tx.makeRetriesDue(accountID: accountID, now: now) }
        scheduleSending()
    }

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
    /// While the account waits for sign-in it sends nothing until woken, and
    /// a read that fails is tried again after a pause.
    private func drainQueue(_ lane: PendingAction.Lane) async {
        let accountID = accountID
        var failedReads = 0
        while !Task.isCancelled, !(lane == .compose && isStoppingDrafts) {
            wakeRequests.remove(lane)
            if waitsForSignIn {
                await sleepUntilWoken(lane, limit: nil)
                continue
            }
            // With no label send under way, a label row still marked as going
            // out lost its outcome. It counts as due, and `sendDueActions()`
            // puts it back in the queue behind a backoff.
            let recovers = lane == .labels && labelSendsInFlight == 0
            let dueTimes: [Date]
            do {
                dueTimes = try await cache.read { tx in
                    try tx.pendingActions(accountID: accountID).filter { $0.kind.lane == lane }.compactMap { row -> Date? in
                        switch row.state {
                        case .queued: row.notBefore
                        case .sending, .undone: recovers ? .distantPast : nil
                        case .sent, .failed: nil
                        }
                    }
                }
                failedReads = 0
            } catch {
                // The rows are still there. Ending the loop would leave them
                // until the next change wakes the lane.
                failedReads += 1
                await sleepUntilWoken(lane, limit: min(pow(2, Double(failedReads)), 60))
                continue
            }
            guard let next = dueTimes.min() else {
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

    /// Sleeps until `wake(_:)` is called for `lane` or `limit` seconds pass;
    /// with no limit, until woken. Returns at once when a wake request is
    /// already pending.
    private func sleepUntilWoken(_ lane: PendingAction.Lane, limit: TimeInterval?) async {
        guard limit.map({ $0 > 0 }) ?? true, !isStopped, !Task.isCancelled, !wakeRequests.contains(lane) else { return }
        laneWaiterGeneration += 1
        let generation = laneWaiterGeneration
        var timer: Task<Void, Never>?
        if let limit {
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(limit)) } catch { return }
                await self?.wake(lane, generation: generation)
            }
        }
        // Registering and `stop()` both run on the actor without suspending,
        // so a waiter is either resumed by `stop()` or never registered after it.
        await withCheckedContinuation { continuation in
            laneWaiters[lane] = LaneWaiter(generation: generation, continuation: continuation)
        }
        timer?.cancel()
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
    /// conversations that match are combined into one request. With no other
    /// call under way, a row an earlier call left marked as going out lost
    /// its outcome, as when the write recording it failed. It goes back in
    /// the queue to be sent again after a backoff; until then, later changes
    /// to its conversations keep waiting behind it.
    @discardableResult
    public func sendDueActions() async -> Int {
        let accountID = accountID
        let now = now()
        labelSendsInFlight += 1
        defer { labelSendsInFlight -= 1 }
        let recovers = labelSendsInFlight == 1
        guard let (claimed, due) = try? await write({ tx -> (Int, [PendingAction]) in
            if recovers {
                try tx.requeueLostSends(accountID: accountID, lane: .labels) { now.addingTimeInterval(Self.backoff(after: $0.attempts)) }
            }
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
        /// Gmail may still accept the change. `finish` queues it again.
        case retry(any Error)
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
                await finish(current, outcome: Self.outcome(for: error, of: current))
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
                await finish(action, outcome: Self.outcome(delivering: action, errors: errors), confirmedHistoryID: result.confirmedHistoryID)
            }
        } catch {
            for action in ready {
                let outcome = if let error = error as? GmailError {
                    Self.outcome(delivering: action, errors: [error])
                } else {
                    Self.outcome(for: error, of: action)
                }
                await finish(action, outcome: outcome)
            }
        }
    }

    /// How many tries a change gets against an error that may pass, other
    /// than a network failure or a rejected sign-in, before it counts as
    /// refused.
    static let retryLimit = 8

    /// How many unreadable answers to a delivered change make it count as
    /// sent. Gmail most likely made the change, and the next pass brings
    /// what it did.
    static let unreadableAnswerLimit = 3

    /// How long a change waits for its next try after `attempts` tries.
    static func backoff(after attempts: Int) -> TimeInterval {
        min(pow(2, Double(attempts)), 300)
    }

    /// What becomes of `row` after `error`. A change that can't reach Gmail
    /// keeps trying, as does one that failed outside Gmail, such as on a
    /// token that couldn't be refreshed, and a rejected sign-in waits for the
    /// account to sign in again (`finish`). Any other error that may pass
    /// gets `retryLimit` tries.
    static func outcome(for error: any Error, of row: PendingAction) -> Outcome {
        guard let error = error as? GmailError else { return .retry(error) }
        guard shouldRetry(error) else { return .failed(String(describing: error)) }
        switch error {
        case .transport, .unauthorized: return .retry(error)
        default: return row.attempts < retryLimit ? .retry(error) : .failed(String(describing: error))
        }
    }

    /// What becomes of `action` after Gmail answered its delivery with
    /// `errors` for its conversations or messages. A refusal among them
    /// decides, then a rejected sign-in.
    static func outcome(delivering action: PendingAction, errors: [GmailError]) -> Outcome {
        guard let first = errors.first else { return .sent }
        if action.attempts >= unreadableAnswerLimit, errors.allSatisfy(isUnreadableAnswer) { return .sent }
        let deciding = errors.first(where: { !shouldRetry($0) }) ?? errors.first(where: { $0 == .unauthorized }) ?? first
        return outcome(for: deciding, of: action)
    }

    private static func isUnreadableAnswer(_ error: GmailError) -> Bool {
        if case .decoding = error { true } else { false }
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
    /// change; the pass that reaches it drops the row. A retry waits out a
    /// backoff, except after a rejected sign-in: then the send loops wait for
    /// `resumeAfterSignIn()`, and the row goes as soon as they resume.
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
        case .retry(let error):
            row.state = .queued
            // Error descriptions carry no message content or addresses.
            row.lastError = error is GmailError ? String(describing: error) : String(describing: type(of: error))
            if (error as? GmailError) == .unauthorized {
                row.notBefore = now
                waitsForSignIn = true
            } else {
                row.notBefore = now.addingTimeInterval(Self.backoff(after: row.attempts))
            }
        case .failed(let message):
            row.state = .failed
            row.lastError = message
        }
        let failed = if case .failed = outcome { true } else { false }
        // Undone during the request: its inverse is queued behind it, so the row
        // just goes, whatever Gmail answered.
        let reported = await recordOutcome { [row] tx -> Bool in
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

    /// Tries a failed write twice more after a short pause. A row whose
    /// outcome isn't written stays marked as going out, holding back later
    /// changes to its conversations, until the next `sendDueActions()` puts
    /// a label row back in the queue, or the next launch any row. Nil when
    /// no try landed.
    func recordOutcome<T: Sendable>(_ updates: @escaping @Sendable (CacheTransaction) throws -> T) async -> T? {
        for attempt in 1...3 {
            do {
                return try await write(updates)
            } catch is CancellationError {
                return nil
            } catch {
                if attempt < 3 { try? await sleep(.milliseconds(100 * attempt)) }
            }
        }
        return nil
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
