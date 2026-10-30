import Foundation
import GmailAPI
import MailStore

/// Serializes cache/config mutations while allowing metadata reads to remain
/// outside the gate. A slow Gmail read must not block a user's new schedule.
actor SnoozeOperationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        if held { await withCheckedContinuation { waiters.append($0) } }
        else { held = true }
        defer {
            if waiters.isEmpty { held = false }
            else { waiters.removeFirst().resume() }
        }
        return try await operation()
    }
}

extension SnoozeKeeper {
    public func snooze(target: MailActionTarget, until wakeAt: Date) async throws -> ActionReceipt? {
        switch target {
        case .threads(let ids): return try await snooze(threadIDs: ids, until: wakeAt)
        case .messages(let ids):
            return try await operations.perform { [self] in try await snoozeExactMessages(ids, until: wakeAt) }
        }
    }

    private func snoozeExactMessages(_ ids: [String], until wakeAt: Date) async throws -> ActionReceipt? {
        guard !isStopped else { throw CancellationError() }
        guard let receipt = try await engine.snoozeMessages(ids, until: wakeAt), let change = receipt.messageSnooze else { return nil }
        try await accounts.applyMessageSnoozes(change.records, replacingThreads: change.splitThreads, accountID: engine.accountID)
        scheduleNextCheck()
        return receipt
    }

    public func unsnooze(target: MailActionTarget) async throws {
        switch target {
        case .threads(let ids): try await unsnooze(threadIDs: ids)
        case .messages(let ids):
            try await operations.perform { [self] in try await unsnoozeExactMessages(ids) }
        }
    }

    private func unsnoozeExactMessages(_ ids: [String]) async throws {
        guard !isStopped else { throw CancellationError() }
        // A legacy thread snooze must first become independent schedules so
        // waking one row does not wake its siblings.
        let threadHolds = try await engine.snoozeHolds()
        let accountID = engine.accountID
        let legacy = try await engine.cache.read { tx in
            try ids.filter { id in
                guard let message = try tx.message(id: id, accountID: accountID) else { return false }
                return threadHolds[message.threadID] != nil
            }
        }
        if !legacy.isEmpty, let receipt = try await engine.snoozeMessages(legacy, until: engine.now()), let change = receipt.messageSnooze {
            try await accounts.applyMessageSnoozes(change.records, replacingThreads: change.splitThreads, accountID: accountID)
        }
        let records = try await engine.messageSnoozeHolds().filter { ids.contains($0.messageID) }
        let finished = try await engine.endMessageSnoozes(waking: records, releasing: [])
        try await accounts.deleteMessageSnoozes(finished, accountID: accountID)
        scheduleNextCheck()
    }

    /// Working holds win after a crash between cache and config writes. Each
    /// conversion saves every replacement before removing its old records.
    private func synchronizeSnoozeRecords() async throws {
        guard !isStopped else { throw CancellationError() }
        let accountID = engine.accountID
        let threadHolds = try await engine.snoozeHolds()
        let messageHolds = try await engine.messageSnoozeHolds()
        let threads = try await accounts.snoozes(accountID: accountID)
        let messages = try await accounts.messageSnoozes(accountID: accountID)
        let threadRecords = threadHolds.map { SnoozeRecord(accountID: accountID, threadID: $0.key, wakeAt: $0.value, createdAt: engine.now()) }
        let supersededMessages = messages.filter { threadHolds[$0.threadID] != nil }
        let independent = messageHolds.filter { threadHolds[$0.threadID] == nil }
        let splitIDs = Set(independent.map(\.threadID))
        let supersededThreads = Dictionary(uniqueKeysWithValues: threads.filter { threadHolds[$0.threadID] == nil && splitIDs.contains($0.threadID) }.map { ($0.threadID, $0.wakeAt) })
        try await accounts.applySnoozeChanges(threads: threadRecords, messages: independent,
            removingThreads: supersededThreads, removingMessages: supersededMessages, accountID: accountID)
    }

    func reconcileSnoozes() async throws {
        try await operations.perform { [self] in try await synchronizeSnoozeRecords() }
        let accountID = engine.accountID
        // Hydrate only held/recorded targets. These reads bypass new-mail
        // notification emission and never promote a message into its thread.
        for record in try await accounts.snoozes(accountID: accountID) {
            let state = try await engine.snoozeStates().first { $0.threadID == record.threadID }
            guard state?.isCached != true else { continue }
            let fetched = try await engine.fetchThreadMetadata([record.threadID])
            try await operations.perform { [self] in
                try await restoreThreadRecord(record, updates: fetched.updates, missing: fetched.missing.contains(record.threadID))
            }
        }
        for record in try await accounts.messageSnoozes(accountID: accountID) {
            guard try await !engine.messageSnoozeHolds().contains(where: { $0.messageID == record.messageID }) else { continue }
            let fetched = try await engine.fetchMetadata([record.messageID])
            try await operations.perform { [self] in
                try await restoreMessageRecord(record, update: fetched.updates.first, missing: fetched.missing.contains(record.messageID))
            }
        }
        try await operations.perform { [self] in try await synchronizeSnoozeRecords() }
    }

    private func restoreThreadRecord(_ record: SnoozeRecord, updates: [CacheTransaction.MessageUpdate], missing: Bool) async throws {
        guard !isStopped else { throw CancellationError() }
        let accountID = engine.accountID
        let records = try await accounts.snoozes(accountID: accountID)
        let messages = try await engine.messageSnoozeHolds()
        guard records.contains(where: { $0.threadID == record.threadID && $0.wakeAt == record.wakeAt }),
              !messages.contains(where: { $0.threadID == record.threadID }) else { return }
        let held = try await engine.snoozeHolds()[record.threadID]
        guard held == nil || held == record.wakeAt else { return }
        if missing {
            let finished = try await engine.endSnoozes(waking: [:], releasing: [record.threadID: record.wakeAt])
            if held == nil || finished[record.threadID] != nil {
                try await accounts.deleteSnooze(accountID: accountID, threadID: record.threadID, wakingAt: record.wakeAt)
            }
        } else { try await engine.restoreThreadSnooze(record, updates: updates, heldUntil: held) }
    }

    private func restoreMessageRecord(_ record: MessageSnoozeRecord, update: CacheTransaction.MessageUpdate?, missing: Bool) async throws {
        guard !isStopped else { throw CancellationError() }
        let accountID = engine.accountID
        let records = try await accounts.messageSnoozes(accountID: accountID)
        let threadHolds = try await engine.snoozeHolds()
        guard records.contains(where: { $0.messageID == record.messageID && $0.revision == record.revision }),
              threadHolds[record.threadID] == nil else { return }
        if missing { try await accounts.deleteMessageSnoozes([record], accountID: accountID) }
        else if let update { _ = try await engine.restoreMessageSnooze(record, update: update) }
    }

    func finishDueSnoozes() async throws {
        guard !isStopped else { throw CancellationError() }
        let now = engine.now()
        var due: [String: Date] = [:]
        var ended: [String: Date] = [:]
        for state in try await engine.snoozeStates() where state.isCached {
            if state.wakeAt <= now { due[state.threadID] = state.wakeAt }
            else if state.isInInbox { ended[state.threadID] = state.wakeAt }
        }
        let finishedThreads = try await engine.endSnoozes(waking: due, releasing: ended)
        let states = try await engine.messageSnoozeStates()
        let dueMessages = states.filter { $0.record.wakeAt <= now }.map(\.record)
        let endedMessages = states.filter { $0.record.wakeAt > now && $0.labels.contains(SystemLabel.inbox) }.map(\.record)
        let finishedMessages = try await engine.endMessageSnoozes(waking: dueMessages, releasing: endedMessages)
        try await accounts.applySnoozeChanges(removingThreads: finishedThreads, removingMessages: finishedMessages, accountID: engine.accountID)
    }
}
