import Foundation
import GmailAPI
import MailStore

struct MessageSnoozeChange: Sendable {
    let messageIDs: [String]
    let wakeAt: Date
    let replaced: [String: MessageSnoozeRecord]
    let records: [MessageSnoozeRecord]
    let splitThreads: [String: Date]
}

struct MessageSnoozeState: Sendable {
    let record: MessageSnoozeRecord
    let labels: Set<String>
}

extension SyncEngine {
    func snoozeMessages(_ ids: [String], until wakeAt: Date) async throws -> ActionReceipt? {
        let ids = Array(Set(ids)).sorted()
        guard !ids.isEmpty else { return nil }
        let accountID = accountID
        let legacyThreads = try await cache.read { tx in
            let holds = try tx.snoozeHolds(accountID: accountID)
            return try Set(ids.compactMap { try tx.message(id: $0, accountID: accountID)?.threadID }).filter { holds[$0] != nil }
        }
        let fetched = try await fetchThreadMetadata(Array(legacyThreads))
        guard fetched.missing.isEmpty else { throw TriageError.incompleteResponse }
        let now = now()
        let notBefore = now.addingTimeInterval(undoHolds.triage)
        let deleted = deletedMessageIDs
        let result = try await write { tx -> ([PendingAction], MessageSnoozeChange) in
            let live = deleted.withLock { tombstones in fetched.updates.filter { !tombstones.contains($0.record.id) } }
            try tx.rebuildThreads(try tx.upsertMessages(live), accountID: accountID)
            let messages = try ids.map { id -> MessageRecord in
                guard let message = try tx.message(id: id, accountID: accountID) else { throw TriageError.incompleteResponse }
                return message
            }
            let threads = Set(messages.map(\.threadID))
            let threadHolds = try tx.snoozeHolds(accountID: accountID)
            var split: [String: Date] = [:]
            var touched = Set(ids)
            for threadID in threads {
                guard let earlier = threadHolds[threadID] else { continue }
                for message in try tx.messages(threadID: threadID, accountID: accountID) {
                    let record = MessageSnoozeRecord(accountID: accountID, messageID: message.id, threadID: threadID, wakeAt: earlier, createdAt: now)
                    try tx.holdMessageSnooze(record)
                    touched.insert(message.id)
                }
                try tx.releaseSnooze(threadID: threadID, wakingAt: earlier, accountID: accountID)
                split[threadID] = earlier
            }
            let previous = Dictionary(uniqueKeysWithValues: try tx.messageSnoozeHolds(accountID: accountID)
                .filter { ids.contains($0.messageID) }.map { ($0.messageID, $0) })
            // A message already out of the Inbox gets its hold and no row.
            let rows = try messages.compactMap { message -> PendingAction? in
                let row = try tx.enqueue(.modifyMessages, accountID: accountID, messageIDs: [message.id],
                    remove: [SystemLabel.inbox], now: now, notBefore: notBefore)
                try tx.holdMessageSnooze(.init(accountID: accountID, messageID: message.id, threadID: message.threadID,
                    wakeAt: wakeAt, createdAt: now))
                return row
            }
            let records = try tx.messageSnoozeHolds(accountID: accountID).filter { touched.contains($0.messageID) }
            return (rows, MessageSnoozeChange(messageIDs: ids, wakeAt: wakeAt, replaced: previous, records: records, splitThreads: split))
        }
        scheduleSending()
        return register(result.0, messageSnooze: result.1)
    }

    func messageSnoozeHolds() async throws -> [MessageSnoozeRecord] {
        let accountID = accountID
        return try await cache.read { try $0.messageSnoozeHolds(accountID: accountID) }
    }

    func messageSnoozeStates() async throws -> [MessageSnoozeState] {
        let accountID = accountID
        return try await cache.read { tx in
            try tx.messageSnoozeHolds(accountID: accountID).map { record in
                MessageSnoozeState(record: record,
                    labels: try tx.currentLabels(threadID: record.threadID, accountID: accountID)[record.messageID] ?? [])
            }
        }
    }

    func restoreMessageSnooze(_ record: MessageSnoozeRecord, update: CacheTransaction.MessageUpdate) async throws -> Bool {
        let accountID = accountID
        let deleted = deletedMessageIDs
        return try await write { tx in
            guard !deleted.withLock({ $0.contains(record.messageID) }) else { return false }
            guard try tx.snoozeHolds(accountID: accountID)[update.record.threadID] == nil else { return true }
            if try tx.messageSnoozeHolds(accountID: accountID).contains(where: { $0.messageID == record.messageID }) { return true }
            try tx.rebuildThreads(try tx.upsertMessages([update]), accountID: accountID)
            var restored = record
            restored.threadID = update.record.threadID
            try tx.holdMessageSnooze(restored)
            return true
        }
    }

    func restoreThreadSnooze(_ record: SnoozeRecord, updates: [CacheTransaction.MessageUpdate], heldUntil: Date?) async throws {
        let accountID = accountID
        let deleted = deletedMessageIDs
        try await write { tx in
            guard try tx.snoozeHolds(accountID: accountID)[record.threadID] == heldUntil,
                  try !tx.messageSnoozeHolds(accountID: accountID).contains(where: { $0.threadID == record.threadID }) else { return }
            let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
            try tx.rebuildThreads(try tx.upsertMessages(live), accountID: accountID)
            try tx.holdSnooze(threadID: record.threadID, until: record.wakeAt, accountID: accountID)
        }
    }

    func endMessageSnoozes(waking: [MessageSnoozeRecord], releasing: [MessageSnoozeRecord]) async throws -> [MessageSnoozeRecord] {
        let accountID = accountID
        let now = now()
        let finished = try await write { tx in
            var finished: [MessageSnoozeRecord] = []
            for record in waking + releasing {
                guard try tx.releaseMessageSnooze(messageID: record.messageID, wakingAt: record.wakeAt, revision: record.revision, accountID: accountID) else { continue }
                let labels = try tx.currentLabels(threadID: record.threadID, accountID: accountID)[record.messageID] ?? []
                if waking.contains(where: { $0.messageID == record.messageID }),
                   !labels.contains(SystemLabel.spam), !labels.contains(SystemLabel.trash),
                   try tx.message(id: record.messageID, accountID: accountID) != nil {
                    _ = try tx.enqueue(.modifyMessages, accountID: accountID, messageIDs: [record.messageID],
                        add: [SystemLabel.inbox], now: now, notBefore: now)
                    try tx.recordWake(threadID: record.threadID, at: now, accountID: accountID)
                }
                finished.append(record)
            }
            return finished
        }
        scheduleSending()
        return finished
    }

    func undoMessageSnoozeHolds(_ change: MessageSnoozeChange) async throws -> (restored: [MessageSnoozeRecord], released: [MessageSnoozeRecord]) {
        let accountID = accountID
        return try await write { tx in
            var restored: [MessageSnoozeRecord] = []
            var released: [MessageSnoozeRecord] = []
            for record in change.records where change.messageIDs.contains(record.messageID) {
                guard try tx.releaseMessageSnooze(messageID: record.messageID, wakingAt: change.wakeAt, revision: record.revision, accountID: accountID) else { continue }
                let labels = try tx.currentLabels(threadID: record.threadID, accountID: accountID)[record.messageID] ?? []
                if let previous = change.replaced[record.messageID], !labels.contains(SystemLabel.inbox) {
                    try tx.holdMessageSnooze(previous)
                    restored.append(previous)
                } else { released.append(record) }
            }
            return (restored, released)
        }
    }

    func restoreReplacedMessageSnoozes(_ records: [MessageSnoozeRecord]) async throws -> [MessageSnoozeRecord] {
        let accountID = accountID
        return try await write { tx in
            let existing = Set(try tx.messageSnoozeHolds(accountID: accountID).map(\.messageID))
            var restored: [MessageSnoozeRecord] = []
            for record in records where !existing.contains(record.messageID) {
                let labels = try tx.currentLabels(threadID: record.threadID, accountID: accountID)[record.messageID]
                guard let labels, !labels.contains(SystemLabel.inbox), try tx.snoozeHolds(accountID: accountID)[record.threadID] == nil else { continue }
                try tx.holdMessageSnooze(record)
                restored.append(record)
            }
            return restored
        }
    }
}
