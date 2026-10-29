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
    public let id: Int64?
    // The engine enriches rows before sending; UI undo can read them safely
    // after history has removed the durable rows. All access holds this lock.
    private let rows: OSAllocatedUnfairLock<[PendingAction]>
    public var actions: [PendingAction] { rows.withLock { $0 } }

    init(actions: [PendingAction]) {
        id = actions.first?.id
        rows = OSAllocatedUnfairLock(initialState: actions)
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

extension SyncEngine {
    /// Applies `action` to the cache at once and queues it for Gmail after the
    /// undo hold. Keep the returned receipt to undo it.
    @discardableResult
    public func perform(_ action: MailAction, threadIDs: [String]) async throws -> ActionReceipt? {
        try await enqueue(action, threadIDs: threadIDs, hold: undoHold)
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
            try await write { tx in
                for action in actions {
                    try Self.undo(action, accountID: accountID, now: now, in: tx)
                }
            }
        } catch {
            unavailableUndoIDs.subtract(ids)
            throw error
        }
        scheduleSending()
    }

    private static func undo(_ action: PendingAction, accountID: String, now: Date, in tx: CacheTransaction) throws {
        guard let id = action.id, let stored = try tx.action(id: id) else {
            try Self.enqueueInverse(of: action, accountID: accountID, now: now, in: tx)
            return
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
        case .undone:
            return
        }
    }

    @discardableResult
    func enqueue(_ action: MailAction, threadIDs: [String], hold: TimeInterval) async throws -> ActionReceipt? {
        guard !threadIDs.isEmpty else { return nil }
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(hold)
        let rows = try await write { tx -> [PendingAction] in
            try threadIDs.removingDuplicates().sorted().map { threadID in
                let threadIDs = [threadID]
                func modify(add: [String] = [], remove: [String] = []) throws -> PendingAction {
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
        scheduleSending()
        let receipt = ActionReceipt(actions: rows)
        undoReceipts = undoReceipts.filter { $0.value.value != nil }
        for row in rows {
            if let id = row.id { undoReceipts[id] = WeakActionReceipt(receipt) }
        }
        return receipt
    }

    /// Queues the reverse of `action` with no hold.
    static func enqueueInverse(of action: PendingAction, accountID: String, now: Date, in tx: CacheTransaction) throws {
        switch action.kind {
        case .trashThreads:
            _ = try tx.enqueue(
                .untrashThreads, accountID: accountID, threadIDs: action.threadIDs,
                remove: [SystemLabel.trash], now: now, notBefore: now
            )
            if !action.messageIDs.isEmpty {
                _ = try tx.enqueue(
                    .modifyMessages, accountID: accountID, messageIDs: action.messageIDs,
                    add: [SystemLabel.trash], now: now, notBefore: now
                )
            }
        case .untrashThreads:
            _ = try tx.enqueue(
                .trashThreads, accountID: accountID, threadIDs: action.threadIDs,
                add: [SystemLabel.trash], now: now, notBefore: now
            )
        case .modifyThreads, .modifyMessages:
            // Restore each message exactly: archiving a thread removed INBOX only
            // from the messages that had it, so only those get it back.
            let groups = Dictionary(grouping: action.diff, by: \.value)
                .map { (diff: $0.key, messageIDs: $0.value.map(\.key).sorted()) }
                .sorted { $0.messageIDs.first ?? "" < $1.messageIDs.first ?? "" }
            for group in groups where !group.diff.added.isEmpty || !group.diff.removed.isEmpty {
                _ = try tx.enqueue(
                    .modifyMessages, accountID: accountID, threadIDs: action.threadIDs, messageIDs: group.messageIDs,
                    add: group.diff.removed, remove: group.diff.added, now: now, notBefore: now
                )
            }
        }
    }

    // MARK: Sending

    /// Starts the send loop if it isn't running.
    func scheduleSending() {
        guard sendsAutomatically, !isStopped else { return }
        wakeRequested = true
        if drainTask == nil {
            drainTask = Task { await drainQueue() }
        }
    }

    /// Sends due rows until the queue is empty, checking each second for new
    /// rows, undos and the end of a backoff.
    private func drainQueue() async {
        let accountID = accountID
        while !Task.isCancelled {
            wakeRequested = false
            let next = try? await cache.read { tx in
                try tx.pendingActions(accountID: accountID).filter { $0.state == .queued }.map(\.notBefore).min()
            }
            guard let next = next ?? nil else {
                // A row queued while the read was in flight sets the flag again.
                if wakeRequested { continue }
                break
            }
            let wait = next.timeIntervalSince(now())
            if wait > 0 {
                try? await Task.sleep(for: .seconds(min(wait, 1)))
            } else if await sendDueActions() == 0 {
                // Every due row waits behind an older change to its thread.
                try? await Task.sleep(for: .seconds(1))
            }
        }
        drainTask = nil
    }

    /// Sends every queued row whose hold or backoff has passed and returns how
    /// many it claimed.
    @discardableResult
    public func sendDueActions() async -> Int {
        let accountID = accountID
        let now = now()
        guard let due = try? await write({ tx in try tx.claimDueActions(accountID: accountID, now: now) }) else {
            return 0
        }
        for action in due {
            await send(action)
        }
        return due.count
    }

    private enum Outcome {
        case sent
        case retry(String)
        case failed
    }

    /// Complete the original label snapshot before any whole-thread mutation.
    /// Existing diffs survive retries; only newly discovered messages are added.
    private func prepare(_ action: PendingAction) async throws -> PendingAction? {
        guard action.kind != .modifyMessages, let id = action.id else { return action }
        var snapshots: [GmailMessage] = []
        for threadID in action.threadIDs {
            let thread: GmailThread
            do {
                thread = try await gmail.thread(id: threadID, format: .metadata)
            } catch GmailError.notFound { continue }
            guard thread.id == threadID, let messages = thread.messages,
                  messages.allSatisfy({ $0.threadId == threadID }) else { throw GmailError.decoding("Thread snapshot") }
            snapshots += messages
        }
        return try await write { [snapshots] tx in
            guard var row = try tx.action(id: id), row.state == .sending else { return nil }
            for message in snapshots where row.diff[message.id] == nil {
                let labels = Set(message.labelIds ?? [])
                row.diff[message.id] = PendingAction.LabelDiff(
                    added: row.addLabelIDs.filter { !labels.contains($0) }.sorted(),
                    removed: row.removeLabelIDs.filter(labels.contains).sorted()
                )
                if row.kind == .trashThreads, labels.contains(SystemLabel.trash) { row.messageIDs.append(message.id) }
            }
            row.messageIDs = row.messageIDs.removingDuplicates().sorted()
            try tx.updateAction(row)
            return row
        }
    }

    private func send(_ action: PendingAction) async {
        guard !isStopped, !Task.isCancelled else { return }
        guard let id = action.id else { return }
        // Undo can reach a claimed row before its turn in this batch.
        let current = try? await cache.read { tx in try tx.action(id: id) }
        guard let current = current ?? nil, current.state == .sending else {
            _ = try? await write { tx in try tx.deleteActionIfUndone(id: id) }
            return
        }
        guard !isStopped, !Task.isCancelled else { return }

        let outcome: Outcome
        var row = current
        do {
            guard let prepared = try await prepare(row) else {
                _ = try? await write { tx in try tx.deleteActionIfUndone(id: id) }
                return
            }
            row = prepared
            undoReceipts[id]?.value?.update(row)
            let failures = try await deliver(row).values.filter { $0 != .notFound }
            if failures.isEmpty {
                outcome = .sent
            } else if failures.allSatisfy({ $0.isRetryable || $0 == .unauthorized }) {
                outcome = .retry(String(describing: failures[0]))
            } else {
                outcome = .failed
            }
        } catch let error as GmailError {
            // Reauthentication can make this request valid again. Keep the
            // user's intent just as we do for an invalid_grant from the provider.
            outcome = error.isRetryable || error == .unauthorized ? .retry(String(describing: error)) : .failed
        } catch {
            // Offline, signed out or cancelled: keep the row and try later.
            outcome = .retry(String(describing: type(of: error)))
        }

        let now = now()
        switch outcome {
        case .sent:
            row.state = .sent
            row.sentAt = now
            row.lastError = nil
        case .retry(let reason):
            row.state = .queued
            row.lastError = reason
            row.notBefore = now.addingTimeInterval(min(pow(2, Double(row.attempts)), 300))
        case .failed:
            break
        }
        let failed = if case .failed = outcome { true } else { false }
        // Undone during the request: its inverse is queued behind it, so the row
        // just goes, whatever Gmail answered.
        let reported = try? await write { [row] tx -> Bool in
            if try tx.deleteActionIfUndone(id: id) { return false }
            if failed {
                try tx.deleteAction(id: id)
            } else {
                try tx.updateAction(row)
            }
            return failed
        }
        if reported == true {
            unavailableUndoIDs.insert(id)
            continuation.yield(.actionFailed("Gmail didn't accept a change, so Tern put the conversation back."))
        }
    }

    private func deliver(_ action: PendingAction) async throws -> [String: GmailError] {
        switch action.kind {
        case .modifyThreads:
            return try await gmail.modifyThreads(
                ids: action.threadIDs, addLabelIDs: action.addLabelIDs, removeLabelIDs: action.removeLabelIDs
            )
        case .trashThreads:
            return try await gmail.trashThreads(ids: action.threadIDs)
        case .untrashThreads:
            return try await gmail.untrashThreads(ids: action.threadIDs)
        case .modifyMessages:
            guard !action.messageIDs.isEmpty else { return [:] }
            try await gmail.batchModifyMessages(
                ids: action.messageIDs, addLabelIDs: action.addLabelIDs, removeLabelIDs: action.removeLabelIDs
            )
            return [:]
        }
    }
}
