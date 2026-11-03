import Foundation
import GRDB

extension AccountStore {
    public func commitmentEntries(accountIDs: Set<String>, includeClosed: Bool = true) async throws -> [CommitmentEntry] {
        try await writer.read { db in try Self.commitmentEntries(db, accountIDs: accountIDs, includeClosed: includeClosed) }
    }

    public func observeCommitments(accountIDs: Set<String>, includeClosed: Bool = true) -> AsyncThrowingStream<[CommitmentEntry], any Error> {
        let values = ValueObservation.tracking { db in
            try Self.commitmentEntries(db, accountIDs: accountIDs, includeClosed: includeClosed)
        }.removeDuplicates().values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reaccepting the same suggestion returns the user's saved corrections, including closed status.
    public func createCommitment(_ record: CommitmentRecord, reminders: [CommitmentReminderRecord] = []) async throws -> CommitmentEntry {
        try await writer.write { db in
            try Self.requireCommitmentAccount(db, accountID: record.accountID)
            try Self.validateCommitment(record)
            if let key = record.acceptanceKey,
               let existing = try CommitmentRecord.filter(Column("accountID") == record.accountID && Column("acceptanceKey") == key).fetchOne(db) {
                return try Self.commitmentEntry(db, record: existing)
            }
            guard try Self.commitment(db, accountID: record.accountID, id: record.id) == nil else { throw CommitmentStoreError.conflict }
            var saved = record
            saved.revision = 1
            try saved.insert(db)
            try Self.replaceCommitmentReminders(db, record: saved, requested: reminders, existing: [])
            return try Self.requireCommitmentEntry(db, accountID: saved.accountID, id: saved.id)
        }
    }

    /// Atomically saves the editor's record and reminder choices. Empty reminders cancels them.
    public func saveCommitment(_ entry: CommitmentEntry, expectedRevision: Int, now: Date = Date()) async throws -> CommitmentEntry {
        try await writer.write { db in
            try Self.requireCommitmentAccount(db, accountID: entry.record.accountID)
            let current = try Self.requireCommitmentEntry(db, accountID: entry.record.accountID, id: entry.record.id)
            guard current.record.revision == expectedRevision else { throw CommitmentStoreError.conflict }
            guard Self.sameCommitmentSource(current.record, entry.record) else { throw CommitmentStoreError.invalidRecord }
            var saved = entry.record
            saved.createdAt = current.record.createdAt
            saved.updatedAt = now
            saved.revision = try Self.nextCommitmentRevision(current.record)
            try Self.validateCommitment(saved)
            try saved.update(db)
            // Reopening alone does not rearm reminders. An explicit editor choice can add a new one.
            try Self.replaceCommitmentReminders(db, record: saved, requested: entry.reminders, existing: current.reminders,
                invalidateNoReplyEvidence: Self.normalizedCommitmentOwner(current.record.ownerEmail) != Self.normalizedCommitmentOwner(saved.ownerEmail))
            return try Self.requireCommitmentEntry(db, accountID: saved.accountID, id: saved.id)
        }
    }

    public func setCommitmentStatus(accountID: String, id: String, status: CommitmentStatus,
                                    expectedRevision: Int, now: Date = Date()) async throws -> CommitmentEntry {
        try await writer.write { db in
            try Self.requireCommitmentAccount(db, accountID: accountID)
            var entry = try Self.requireCommitmentEntry(db, accountID: accountID, id: id)
            guard entry.record.revision == expectedRevision else { throw CommitmentStoreError.conflict }
            entry.record.status = status
            entry.record.updatedAt = now
            entry.record.revision = try Self.nextCommitmentRevision(entry.record)
            try Self.validateCommitment(entry.record)
            try entry.record.update(db)
            if status != .open { try Self.deleteCommitmentReminders(db, accountID: accountID, id: id) }
            return try Self.requireCommitmentEntry(db, accountID: accountID, id: id)
        }
    }

    public func snoozeCommitmentReminder(accountID: String, commitmentID: String, kind: CommitmentReminderKind,
                                         until: Date, expectedRevision: Int, now: Date = Date()) async throws -> CommitmentEntry {
        try await writer.write { db in
            try Self.requireCommitmentAccount(db, accountID: accountID)
            var entry = try Self.requireCommitmentEntry(db, accountID: accountID, id: commitmentID)
            guard entry.record.revision == expectedRevision else { throw CommitmentStoreError.conflict }
            guard entry.record.status == .open, until.timeIntervalSince1970.isFinite,
                  let index = entry.reminders.firstIndex(where: { $0.kind == kind }) else { throw CommitmentStoreError.invalidRecord }
            entry.record.updatedAt = now
            entry.record.revision = try Self.nextCommitmentRevision(entry.record)
            try Self.validateCommitment(entry.record)
            try entry.record.update(db)
            var reminder = entry.reminders[index]
            reminder.remindAt = until
            reminder.deliveredAt = nil
            reminder.notificationID = nil
            reminder.revision = entry.record.revision
            // Moving a date cannot undo evidence that the requested reply arrived.
            try reminder.update(db)
            return try Self.requireCommitmentEntry(db, accountID: accountID, id: commitmentID)
        }
    }

    public func cancelCommitmentReminder(accountID: String, commitmentID: String, kind: CommitmentReminderKind,
                                         expectedRevision: Int, now: Date = Date()) async throws -> CommitmentEntry {
        try await writer.write { db in
            try Self.requireCommitmentAccount(db, accountID: accountID)
            var entry = try Self.requireCommitmentEntry(db, accountID: accountID, id: commitmentID)
            guard entry.record.revision == expectedRevision else { throw CommitmentStoreError.conflict }
            entry.record.updatedAt = now
            entry.record.revision = try Self.nextCommitmentRevision(entry.record)
            try Self.validateCommitment(entry.record)
            try entry.record.update(db)
            try db.execute(sql: "DELETE FROM commitmentReminder WHERE accountID = ? AND commitmentID = ? AND kind = ?",
                           arguments: [accountID, commitmentID, kind.rawValue])
            return try Self.requireCommitmentEntry(db, accountID: accountID, id: commitmentID)
        }
    }

    /// Returns only pending, due reminders in each entry. Use commitmentEntries for editing a full record.
    public func dueCommitmentReminders(accountIDs: Set<String>, now: Date) async throws -> [CommitmentEntry] {
        try await commitmentEntries(accountIDs: accountIDs, includeClosed: false).compactMap { entry in
            let due = entry.reminders.filter { $0.isPending && $0.remindAt <= now }
            return due.isEmpty ? nil : CommitmentEntry(record: entry.record, reminders: due)
        }
    }

    /// The caller validates sender/thread evidence. This guard rejects old, duplicate or stale replies.
    public func recordCommitmentReply(accountID: String, commitmentID: String, messageID: String, receivedAt: Date,
                                       expectedReminderRevision: Int, now: Date = Date()) async throws -> Bool {
        try await writer.write { db in
            try Self.requireCommitmentAccount(db, accountID: accountID)
            guard var record = try Self.commitment(db, accountID: accountID, id: commitmentID), record.status == .open,
                  var reminder = try Self.commitmentReminder(db, accountID: accountID, id: commitmentID, kind: .noReply),
                  reminder.revision == expectedReminderRevision, reminder.receivedReplyMessageID == nil,
                  !messageID.isEmpty, messageID != reminder.baselineMessageID,
                  receivedAt.timeIntervalSince1970.isFinite, receivedAt > reminder.baselineDate else { return false }
            record.revision = try Self.nextCommitmentRevision(record)
            record.updatedAt = now
            try Self.validateCommitment(record)
            reminder.receivedReplyMessageID = messageID
            reminder.receivedReplyAt = receivedAt
            reminder.revision = record.revision
            try record.update(db)
            try reminder.update(db)
            return true
        }
    }

    /// Acknowledges an actual notification submission only for the still-current due reminder.
    public func markCommitmentReminderDelivered(accountID: String, commitmentID: String, kind: CommitmentReminderKind,
                                                expectedReminderRevision: Int, notificationID: String? = nil,
                                                at: Date = Date()) async throws -> Bool {
        try await writer.write { db in
            try Self.requireCommitmentAccount(db, accountID: accountID)
            guard var record = try Self.commitment(db, accountID: accountID, id: commitmentID), record.status == .open,
                  var reminder = try Self.commitmentReminder(db, accountID: accountID, id: commitmentID, kind: kind),
                  reminder.revision == expectedReminderRevision, reminder.isPending,
                  at.timeIntervalSince1970.isFinite, reminder.remindAt <= at else { return false }
            record.revision = try Self.nextCommitmentRevision(record)
            record.updatedAt = at
            reminder.deliveredAt = at
            reminder.notificationID = notificationID
            reminder.revision = record.revision
            try record.update(db)
            try reminder.update(db)
            return true
        }
    }
}

private extension AccountStore {
    static func requireCommitmentAccount(_ db: Database, accountID: String) throws {
        let available = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM account WHERE id = ?
            AND NOT EXISTS(SELECT 1 FROM pendingAccountRemoval WHERE accountID = ?))
            """, arguments: [accountID, accountID]) ?? false
        guard available else { throw CommitmentStoreError.unavailableAccount }
    }

    static func commitmentEntries(_ db: Database, accountIDs: Set<String>, includeClosed: Bool) throws -> [CommitmentEntry] {
        guard !accountIDs.isEmpty else { return [] }
        let ids = accountIDs.sorted()
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let status = includeClosed ? "" : " AND status = 'open'"
        let records = try CommitmentRecord.fetchAll(db, sql: """
            SELECT * FROM commitment WHERE accountID IN (\(placeholders))\(status)
            AND NOT EXISTS(SELECT 1 FROM pendingAccountRemoval p WHERE p.accountID = commitment.accountID)
            ORDER BY dueAt IS NULL, dueAt, createdAt, accountID, id
            """, arguments: StatementArguments(ids))
        let reminders = try CommitmentReminderRecord.fetchAll(db, sql: """
            SELECT * FROM commitmentReminder WHERE accountID IN (\(placeholders)) ORDER BY remindAt, kind
            """, arguments: StatementArguments(ids))
        let grouped = Dictionary(grouping: reminders) { "\($0.accountID.utf8.count):\($0.accountID)\($0.commitmentID)" }
        return records.map { record in
            let entry = CommitmentEntry(record: record)
            return CommitmentEntry(record: record, reminders: grouped[entry.id] ?? [])
        }
    }

    static func commitment(_ db: Database, accountID: String, id: String) throws -> CommitmentRecord? {
        try CommitmentRecord.filter(Column("accountID") == accountID && Column("id") == id).fetchOne(db)
    }

    static func commitmentReminder(_ db: Database, accountID: String, id: String, kind: CommitmentReminderKind) throws -> CommitmentReminderRecord? {
        try CommitmentReminderRecord.filter(Column("accountID") == accountID && Column("commitmentID") == id && Column("kind") == kind.rawValue).fetchOne(db)
    }

    static func commitmentEntry(_ db: Database, record: CommitmentRecord) throws -> CommitmentEntry {
        let reminders = try CommitmentReminderRecord.filter(Column("accountID") == record.accountID && Column("commitmentID") == record.id)
            .order(Column("remindAt"), Column("kind")).fetchAll(db)
        return CommitmentEntry(record: record, reminders: reminders)
    }

    static func requireCommitmentEntry(_ db: Database, accountID: String, id: String) throws -> CommitmentEntry {
        guard let record = try commitment(db, accountID: accountID, id: id) else { throw CommitmentStoreError.notFound }
        return try commitmentEntry(db, record: record)
    }

    static func nextCommitmentRevision(_ record: CommitmentRecord) throws -> Int {
        guard record.revision >= 0, record.revision < Int.max else { throw CommitmentStoreError.invalidRecord }
        return record.revision + 1
    }

    static func sameCommitmentSource(_ a: CommitmentRecord, _ b: CommitmentRecord) -> Bool {
        a.accountID == b.accountID && a.id == b.id && a.threadID == b.threadID
            && a.sourceMessageID == b.sourceMessageID && a.sourceMessageDate == b.sourceMessageDate
            && a.sourceSubject == b.sourceSubject && a.acceptanceKey == b.acceptanceKey
    }

    static func validateCommitment(_ record: CommitmentRecord) throws {
        let required = [record.accountID, record.id, record.threadID, record.sourceMessageID, record.title]
        let dates = [record.sourceMessageDate, record.createdAt, record.updatedAt] + [record.dueAt].compactMap { $0 }
        guard required.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              dates.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              record.acceptanceKey.map({ !$0.isEmpty }) ?? true else { throw CommitmentStoreError.invalidRecord }
    }

    static func deleteCommitmentReminders(_ db: Database, accountID: String, id: String) throws {
        try db.execute(sql: "DELETE FROM commitmentReminder WHERE accountID = ? AND commitmentID = ?", arguments: [accountID, id])
    }

    static func normalizedCommitmentOwner(_ address: String?) -> String {
        (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func replaceCommitmentReminders(_ db: Database, record: CommitmentRecord,
                                           requested: [CommitmentReminderRecord], existing: [CommitmentReminderRecord],
                                           invalidateNoReplyEvidence: Bool = false) throws {
        guard Set(requested.map(\.kind)).count == requested.count else { throw CommitmentStoreError.invalidRecord }
        try deleteCommitmentReminders(db, accountID: record.accountID, id: record.id)
        guard record.status == .open else { return }
        for candidate in requested {
            guard candidate.accountID == record.accountID, candidate.commitmentID == record.id,
                  !candidate.baselineMessageID.isEmpty, candidate.baselineDate.timeIntervalSince1970.isFinite,
                  candidate.remindAt.timeIntervalSince1970.isFinite,
                  candidate.baselineHistoryID.map({ $0 >= 0 }) ?? true else { throw CommitmentStoreError.invalidRecord }
            let old = existing.first { $0.kind == candidate.kind }
            let unchanged = old.map {
                $0.remindAt == candidate.remindAt && $0.baselineMessageID == candidate.baselineMessageID
                    && $0.baselineDate == candidate.baselineDate && $0.baselineHistoryID == candidate.baselineHistoryID
                    && !(invalidateNoReplyEvidence && candidate.kind == .noReply)
            } ?? false
            var reminder = candidate
            reminder.receivedReplyMessageID = unchanged ? old?.receivedReplyMessageID : nil
            reminder.receivedReplyAt = unchanged ? old?.receivedReplyAt : nil
            reminder.deliveredAt = unchanged ? old?.deliveredAt : nil
            reminder.notificationID = unchanged ? old?.notificationID : nil
            reminder.revision = record.revision
            try reminder.insert(db)
        }
    }
}
