import Foundation
import GRDB

extension AccountStore {
    public func automaticFollowUps(accountIDs: Set<String>) async throws -> [AutomaticFollowUpRecord] {
        try await writer.read { db in try Self.automaticFollowUps(db, accountIDs: accountIDs) }
    }

    /// Applies settings before delivery starts. Inactive schedules retain their reply evidence.
    public func configureAutomaticFollowUps(accountIDs: Set<String>, activeAccountIDs: Set<String>? = nil,
                                             enabled: Bool, delayDays: Int,
                                             enabledSince: Date, now: Date = Date()) async throws -> Set<String> {
        try Task.checkCancellation()
        let activeIDs = activeAccountIDs ?? accountIDs
        guard (1...365).contains(delayDays), enabledSince.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, activeIDs.isSubset(of: accountIDs) else { throw CommitmentStoreError.invalidRecord }
        return try await writer.write { db in
            try Task.checkCancellation()
            var newEnableEpochs: Set<String> = []
            var policies: [String: AutomaticFollowUpPolicy] = [:]
            for accountID in accountIDs {
                try Self.requireCommitmentAccount(db, accountID: accountID)
                let previous = try AutomaticFollowUpPolicy.fetchOne(db, key: accountID)
                let active = activeIDs.contains(accountID)
                let adopting = previous?.active != true || (enabled && previous?.enabled == false)
                let adoptedAt = active ? (adopting ? now : previous?.adoptedAt ?? now) : previous?.adoptedAt
                if let previous, enabled && active && (!previous.enabled || !previous.active
                    || previous.enabledSince.databaseValue != enabledSince.databaseValue) {
                    newEnableEpochs.insert(accountID)
                }
                let policy = AutomaticFollowUpPolicy(accountID: accountID, enabled: enabled,
                    delayDays: delayDays, enabledSince: enabledSince, active: active, adoptedAt: adoptedAt)
                try policy.save(db)
                policies[accountID] = policy
            }
            var removed: Set<String> = []
            for var automatic in try Self.automaticFollowUps(db, accountIDs: accountIDs) where automatic.managed {
                var entry = try Self.requireCommitmentEntry(db, accountID: automatic.accountID, id: automatic.commitmentID)
                guard entry.record.status == .open, let policy = policies[automatic.accountID] else { continue }
                let scheduleEnabled = policy.enabled && policy.active
                let old = entry.reminders.first { $0.kind == .noReply }
                let due = automatic.latestOutgoingDate.addingTimeInterval(Double(delayDays) * 86_400)
                let changedDate = old?.remindAt != due
                let eligible: Bool
                if !scheduleEnabled { eligible = automatic.eligibleForAlerts }
                else if !automatic.scheduleEnabled || newEnableEpochs.contains(automatic.accountID) { eligible = due > policy.adoptionBoundary && due > now }
                else if !automatic.eligibleForAlerts { eligible = changedDate && due > now && due > policy.adoptionBoundary }
                else { eligible = true }
                guard automatic.scheduleEnabled != scheduleEnabled || automatic.delayDays != delayDays
                        || automatic.eligibleForAlerts != eligible || changedDate || newEnableEpochs.contains(automatic.accountID) else { continue }
                automatic.scheduleEnabled = scheduleEnabled
                automatic.delayDays = delayDays
                automatic.eligibleForAlerts = eligible
                automatic.revision = try Self.nextAutomaticRevision(automatic.revision)
                entry.record.revision = try Self.nextCommitmentRevision(entry.record)
                entry.record.updatedAt = now
                var reminder = old ?? CommitmentReminderRecord(accountID: automatic.accountID, commitmentID: automatic.commitmentID,
                    kind: .noReply, remindAt: due, baselineMessageID: automatic.latestOutgoingMessageID, baselineDate: automatic.latestOutgoingDate)
                if let id = reminder.notificationID { removed.insert(id) }
                reminder.remindAt = due
                reminder.deliveredAt = nil
                reminder.notificationID = nil
                reminder.revision = entry.record.revision
                try entry.record.update(db)
                try reminder.save(db)
                try automatic.update(db)
            }
            try Task.checkCancellation()
            return removed
        }
    }

    /// A stale discovery cannot undo a disabled setting or an already newer outgoing baseline.
    public func reconcileAutomaticFollowUp(_ candidate: AutomaticFollowUpCandidate, delayDays: Int,
                                            eligibleForAlerts: Bool, now: Date = Date()) async throws -> AutomaticFollowUpMutation {
        try Task.checkCancellation()
        try Self.validateAutomaticCandidate(candidate, delayDays: delayDays, now: now)
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireCommitmentAccount(db, accountID: candidate.accountID)
            let policy = try AutomaticFollowUpPolicy.fetchOne(db, key: candidate.accountID)
            let existing = try AutomaticFollowUpRecord.filter(Column("accountID") == candidate.accountID && Column("threadID") == candidate.threadID).fetchOne(db)
            var entry = try existing.map { try Self.requireCommitmentEntry(db, accountID: $0.accountID, id: $0.commitmentID) }
            guard policy.map({ $0.enabled && $0.active && $0.delayDays == delayDays }) ?? true else {
                return AutomaticFollowUpMutation(entry: entry, removedNotificationIDs: [])
            }
            let due = candidate.outgoingDate.addingTimeInterval(Double(delayDays) * 86_400)
            let candidateEligible = eligibleForAlerts && (policy.map { due > $0.adoptionBoundary } ?? true)
            var automatic: AutomaticFollowUpRecord
            if let existing {
                automatic = existing
                guard existing.managed, entry?.record.status == .open else {
                    return AutomaticFollowUpMutation(entry: entry, removedNotificationIDs: [])
                }
                if candidate.outgoingMessageID == existing.latestOutgoingMessageID {
                    guard candidate.outgoingDate == existing.latestOutgoingDate else { throw CommitmentStoreError.invalidRecord }
                } else if candidate.outgoingDate <= existing.latestOutgoingDate {
                    return AutomaticFollowUpMutation(entry: entry, removedNotificationIDs: [])
                }
            } else {
                // A manually tracked thread always wins, including completed or dismissed work.
                if let manual = try CommitmentRecord.filter(Column("accountID") == candidate.accountID && Column("threadID") == candidate.threadID)
                    .order(Column("createdAt"), Column("id")).fetchOne(db) {
                    entry = try Self.commitmentEntry(db, record: manual)
                    automatic = Self.automaticRecord(candidate, commitmentID: manual.id, delayDays: delayDays, eligible: false, managed: false)
                    try automatic.insert(db)
                    return AutomaticFollowUpMutation(entry: entry, removedNotificationIDs: [])
                }
                let record = CommitmentRecord(accountID: candidate.accountID, threadID: candidate.threadID,
                    sourceMessageID: candidate.outgoingMessageID, sourceMessageDate: candidate.outgoingDate,
                    sourceSubject: candidate.sourceSubject, title: candidate.title, ownerName: candidate.ownerName,
                    ownerEmail: candidate.ownerEmail, direction: .waitingFor, createdAt: now, revision: 1)
                try Self.validateCommitment(record)
                try record.insert(db)
                let reminder = CommitmentReminderRecord(accountID: record.accountID, commitmentID: record.id, kind: .noReply,
                    remindAt: due, baselineMessageID: candidate.outgoingMessageID, baselineDate: candidate.outgoingDate,
                    baselineHistoryID: candidate.baselineHistoryID, revision: record.revision)
                try reminder.insert(db)
                automatic = Self.automaticRecord(candidate, commitmentID: record.id, delayDays: delayDays, eligible: candidateEligible)
                try automatic.insert(db)
                return AutomaticFollowUpMutation(entry: CommitmentEntry(record: record, reminders: [reminder]), removedNotificationIDs: [])
            }
            guard var current = entry else { throw CommitmentStoreError.notFound }
            let old = current.reminders.first { $0.kind == .noReply }
            let newerBaseline = automatic.latestOutgoingMessageID != candidate.outgoingMessageID
            let changedDate = old?.remindAt != due
            let eligible = newerBaseline ? candidateEligible
                : (!automatic.scheduleEnabled ? candidateEligible && due > now
                   : automatic.eligibleForAlerts || (changedDate && due > now && candidateEligible))
            guard newerBaseline || changedDate || !automatic.scheduleEnabled || automatic.delayDays != delayDays
                    || automatic.eligibleForAlerts != eligible else {
                return AutomaticFollowUpMutation(entry: current, removedNotificationIDs: [])
            }
            let removed = Set([old?.notificationID].compactMap { $0 })
            automatic.latestOutgoingMessageID = candidate.outgoingMessageID
            automatic.latestOutgoingDate = candidate.outgoingDate
            automatic.delayDays = delayDays
            automatic.eligibleForAlerts = eligible
            automatic.scheduleEnabled = true
            automatic.revision = try Self.nextAutomaticRevision(automatic.revision)
            current.record.revision = try Self.nextCommitmentRevision(current.record)
            current.record.updatedAt = now
            if newerBaseline {
                current.record.ownerName = candidate.ownerName
                current.record.ownerEmail = candidate.ownerEmail
            }
            var reminder = CommitmentReminderRecord(accountID: candidate.accountID, commitmentID: current.record.id,
                kind: .noReply, remindAt: due, baselineMessageID: candidate.outgoingMessageID, baselineDate: candidate.outgoingDate,
                baselineHistoryID: candidate.baselineHistoryID, revision: current.record.revision)
            if !newerBaseline {
                reminder.receivedReplyMessageID = old?.receivedReplyMessageID
                reminder.receivedReplyAt = old?.receivedReplyAt
            }
            try current.record.update(db)
            try reminder.save(db)
            try automatic.update(db)
            return AutomaticFollowUpMutation(entry: try Self.requireCommitmentEntry(db, accountID: candidate.accountID, id: current.record.id),
                removedNotificationIDs: removed)
        }
    }

    public func disableAutomaticFollowUps(accountIDs: Set<String>, now: Date = Date()) async throws -> Set<String> {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            guard now.timeIntervalSince1970.isFinite else { throw CommitmentStoreError.invalidRecord }
            for accountID in accountIDs {
                try Self.requireCommitmentAccount(db, accountID: accountID)
                var policy = try AutomaticFollowUpPolicy.fetchOne(db, key: accountID)
                    ?? AutomaticFollowUpPolicy(accountID: accountID, enabled: false, delayDays: 3, enabledSince: now,
                        active: true, adoptedAt: nil)
                policy.enabled = false
                try policy.save(db)
            }
            var removed: Set<String> = []
            for var automatic in try Self.automaticFollowUps(db, accountIDs: accountIDs) where automatic.managed && automatic.scheduleEnabled {
                automatic.scheduleEnabled = false
                automatic.revision = try Self.nextAutomaticRevision(automatic.revision)
                var entry = try Self.requireCommitmentEntry(db, accountID: automatic.accountID, id: automatic.commitmentID)
                entry.record.revision = try Self.nextCommitmentRevision(entry.record)
                entry.record.updatedAt = now
                if var reminder = entry.reminders.first(where: { $0.kind == .noReply }) {
                    if let id = reminder.notificationID { removed.insert(id) }
                    reminder.deliveredAt = nil; reminder.notificationID = nil; reminder.revision = entry.record.revision
                    try reminder.update(db)
                }
                try entry.record.update(db)
                try automatic.update(db)
            }
            return removed
        }
    }

    public func claimAutomaticFollowUpDraft(accountID: String, commitmentID: String, expectedReminderRevision: Int,
                                             draftID: String = UUID().uuidString, now: Date = Date()) async throws -> AutomaticFollowUpDraftReceipt? {
        try Task.checkCancellation()
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireCommitmentAccount(db, accountID: accountID)
            guard !draftID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let automatic = try Self.draftableAutomaticFollowUp(db, accountID: accountID, commitmentID: commitmentID, now: now),
                  let reminder = try Self.commitmentReminder(db, accountID: accountID, id: commitmentID, kind: .noReply),
                  reminder.revision == expectedReminderRevision else { return nil }
            guard try AutomaticFollowUpDraftReceipt.filter(Column("accountID") == accountID && Column("threadID") == automatic.threadID
                && Column("outgoingMessageID") == automatic.latestOutgoingMessageID).fetchOne(db) == nil else { return nil }
            let receipt = AutomaticFollowUpDraftReceipt(accountID: accountID, threadID: automatic.threadID, commitmentID: commitmentID,
                outgoingMessageID: automatic.latestOutgoingMessageID, claimID: UUID().uuidString, draftID: draftID, state: .reserved,
                createdAt: now, updatedAt: now, automationRevision: automatic.revision)
            try receipt.insert(db)
            return receipt
        }
    }

    public func validateAutomaticFollowUpDraftClaim(_ receipt: AutomaticFollowUpDraftReceipt, now: Date = Date()) async throws -> Bool {
        try Task.checkCancellation()
        return try await writer.read { db in
            try Self.requireCommitmentAccount(db, accountID: receipt.accountID)
            guard let stored = try AutomaticFollowUpDraftReceipt.filter(Column("claimID") == receipt.claimID).fetchOne(db),
                  Self.sameAutomaticDraftClaim(stored, receipt), stored.state == .reserved,
                  let automatic = try Self.draftableAutomaticFollowUp(db, accountID: receipt.accountID, commitmentID: receipt.commitmentID, now: now)
            else { return false }
            return automatic.revision == receipt.automationRevision && automatic.latestOutgoingMessageID == receipt.outgoingMessageID
        }
    }

    /// Terminal receipts are retained even if the user later edits or deletes the draft.
    public func finishAutomaticFollowUpDraft(_ receipt: AutomaticFollowUpDraftReceipt, state: AutomaticFollowUpDraftState,
                                              now: Date = Date()) async throws -> Bool {
        guard state != .reserved, now.timeIntervalSince1970.isFinite else { throw CommitmentStoreError.invalidRecord }
        return try await writer.write { db in
            try Self.requireCommitmentAccount(db, accountID: receipt.accountID)
            guard var stored = try AutomaticFollowUpDraftReceipt.filter(Column("claimID") == receipt.claimID).fetchOne(db),
                  Self.sameAutomaticDraftClaim(stored, receipt), stored.state == .reserved else { return false }
            stored.state = state
            stored.updatedAt = now
            try stored.update(db)
            return true
        }
    }
}

extension AccountStore {
    static func stopManagingAutomaticFollowUp(_ db: Database, accountID: String, commitmentID: String,
                                               enableReminder: Bool = false) throws {
        guard var automatic = try AutomaticFollowUpRecord.filter(Column("accountID") == accountID && Column("commitmentID") == commitmentID)
            .fetchOne(db), automatic.managed || (enableReminder && (!automatic.scheduleEnabled || !automatic.eligibleForAlerts)) else { return }
        automatic.managed = false
        if enableReminder { automatic.scheduleEnabled = true; automatic.eligibleForAlerts = true }
        automatic.revision = try nextAutomaticRevision(automatic.revision)
        try automatic.update(db)
    }

    static func replaceAutomaticFollowUpWithManualWork(_ db: Database, record: CommitmentRecord) throws {
        guard let automatic = try AutomaticFollowUpRecord.filter(Column("accountID") == record.accountID && Column("threadID") == record.threadID)
            .fetchOne(db), automatic.managed, automatic.commitmentID != record.id else { return }
        try stopManagingAutomaticFollowUp(db, accountID: record.accountID, commitmentID: automatic.commitmentID)
        var generic = try requireCommitmentEntry(db, accountID: record.accountID, id: automatic.commitmentID)
        generic.record.revision = try nextCommitmentRevision(generic.record)
        generic.record.updatedAt = record.createdAt
        try generic.record.update(db)
        try db.execute(sql: "DELETE FROM commitmentReminder WHERE accountID = ? AND commitmentID = ? AND kind = 'noReply'",
            arguments: [record.accountID, automatic.commitmentID])
    }

    static func automaticReminderAllowsDelivery(_ db: Database, reminder: CommitmentReminderRecord) throws -> Bool {
        guard reminder.kind == .noReply else { return true }
        let suppressed = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM automaticFollowUp WHERE accountID = ? AND commitmentID = ?
                AND (scheduleEnabled = 0 OR eligibleForAlerts = 0))
            """, arguments: [reminder.accountID, reminder.commitmentID]) ?? false
        return !suppressed
    }
}

private struct AutomaticFollowUpPolicy: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "automaticFollowUpPolicy"
    var accountID: String
    var enabled: Bool
    var delayDays: Int
    var enabledSince: Date
    var active: Bool
    var adoptedAt: Date?

    var adoptionBoundary: Date { max(enabledSince, adoptedAt ?? enabledSince) }
}

private extension AccountStore {
    static func sameAutomaticDraftClaim(_ a: AutomaticFollowUpDraftReceipt, _ b: AutomaticFollowUpDraftReceipt) -> Bool {
        a.claimID == b.claimID && a.draftID == b.draftID && a.accountID == b.accountID && a.threadID == b.threadID
            && a.commitmentID == b.commitmentID && a.outgoingMessageID == b.outgoingMessageID && a.automationRevision == b.automationRevision
    }

    static func automaticFollowUps(_ db: Database, accountIDs: Set<String>) throws -> [AutomaticFollowUpRecord] {
        guard !accountIDs.isEmpty else { return [] }
        return try AutomaticFollowUpRecord.fetchAll(db, sql: """
            SELECT * FROM automaticFollowUp WHERE accountID IN (\(accountIDs.map { _ in "?" }.joined(separator: ",")))
            AND NOT EXISTS(SELECT 1 FROM pendingAccountRemoval p WHERE p.accountID = automaticFollowUp.accountID)
            ORDER BY accountID, threadID
            """, arguments: StatementArguments(accountIDs.sorted()))
    }

    static func automaticRecord(_ candidate: AutomaticFollowUpCandidate, commitmentID: String, delayDays: Int,
                                eligible: Bool, managed: Bool = true) -> AutomaticFollowUpRecord {
        AutomaticFollowUpRecord(accountID: candidate.accountID, threadID: candidate.threadID, commitmentID: commitmentID,
            managed: managed, latestOutgoingMessageID: candidate.outgoingMessageID, latestOutgoingDate: candidate.outgoingDate,
            delayDays: delayDays, eligibleForAlerts: managed ? eligible : true, scheduleEnabled: true, revision: 1)
    }

    static func nextAutomaticRevision(_ revision: Int) throws -> Int {
        guard revision > 0, revision < Int.max else { throw CommitmentStoreError.invalidRecord }
        return revision + 1
    }

    static func validateAutomaticCandidate(_ candidate: AutomaticFollowUpCandidate, delayDays: Int, now: Date) throws {
        guard (1...365).contains(delayDays), candidate.outgoingDate.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, candidate.baselineHistoryID.map({ $0 >= 0 }) ?? true,
              [candidate.accountID, candidate.threadID, candidate.outgoingMessageID, candidate.title].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { throw CommitmentStoreError.invalidRecord }
    }

    static func draftableAutomaticFollowUp(_ db: Database, accountID: String, commitmentID: String, now: Date) throws -> AutomaticFollowUpRecord? {
        guard now.timeIntervalSince1970.isFinite,
              let automatic = try AutomaticFollowUpRecord.filter(Column("accountID") == accountID && Column("commitmentID") == commitmentID).fetchOne(db),
              automatic.managed, automatic.scheduleEnabled, automatic.eligibleForAlerts,
              let record = try commitment(db, accountID: accountID, id: commitmentID), record.status == .open,
              record.deferredUntil.map({ $0 <= now }) ?? true,
              let reminder = try commitmentReminder(db, accountID: accountID, id: commitmentID, kind: .noReply),
              reminder.receivedReplyMessageID == nil, reminder.remindAt <= now,
              reminder.baselineMessageID == automatic.latestOutgoingMessageID, reminder.baselineDate == automatic.latestOutgoingDate
        else { return nil }
        return automatic
    }
}
