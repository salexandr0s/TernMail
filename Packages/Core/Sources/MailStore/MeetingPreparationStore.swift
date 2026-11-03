import Foundation
import GRDB

extension AccountStore {
    public func meetingPreparationPreferences(for occurrence: MeetingPreparationOccurrence) async throws -> [MeetingPreparationSourcePreference] {
        try Task.checkCancellation()
        try occurrence.validate()
        return try await writer.read { db in
            try Task.checkCancellation()
            try Self.requireMeetingPreparationAccount(db, accountID: occurrence.eventAccountID)
            return try Self.meetingPreparationPreferences(db, occurrence: occurrence)
        }
    }

    /// Removing either account clears its choices from the observed result immediately.
    public func observeMeetingPreparationPreferences(for occurrence: MeetingPreparationOccurrence)
        -> AsyncThrowingStream<[MeetingPreparationSourcePreference], any Error> {
        let values = ValueObservation.tracking { db -> [MeetingPreparationSourcePreference] in
            try occurrence.validate()
            guard try Self.meetingPreparationAccountAvailable(db, accountID: occurrence.eventAccountID) else { return [] }
            return try Self.meetingPreparationPreferences(db, occurrence: occurrence)
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

    /// Nil expects a new preference; replacing a choice requires its current revision token.
    public func setMeetingPreparationPreference(occurrence: MeetingPreparationOccurrence, mailAccountID: String,
                                                  threadID: String, choice: MeetingPreparationSourceChoice,
                                                  expectedRevision: String? = nil, now: Date = Date()) async throws -> MeetingPreparationSourcePreference {
        try Task.checkCancellation()
        try Self.validateMeetingPreparationSource(occurrence, mailAccountID: mailAccountID, threadID: threadID)
        guard now.timeIntervalSince1970.isFinite else { throw MeetingPreparationStoreError.invalidPreference }
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireMeetingPreparationAccount(db, accountID: occurrence.eventAccountID)
            try Self.requireMeetingPreparationAccount(db, accountID: mailAccountID)
            let current = try Self.meetingPreparationPreference(db, occurrence: occurrence, mailAccountID: mailAccountID, threadID: threadID)
            guard current?.revision == expectedRevision else { throw MeetingPreparationStoreError.conflict }
            if let current, current.choice == choice { return current }
            let payload = try String(decoding: JSONEncoder().encode(occurrence), as: UTF8.self)
            let revision = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO meetingPreparationPreference
                    (eventAccountID,calendarID,occurrenceKey,occurrence,mailAccountID,threadID,choice,updatedAt,revision)
                VALUES (?,?,?,?,?,?,?,?,?)
                ON CONFLICT(eventAccountID,calendarID,occurrenceKey,mailAccountID,threadID) DO UPDATE SET
                    occurrence = excluded.occurrence, choice = excluded.choice,
                    updatedAt = excluded.updatedAt, revision = excluded.revision
                """, arguments: [occurrence.eventAccountID, occurrence.calendarID, occurrence.identity.storageKey,
                    payload, mailAccountID, threadID, choice.rawValue, now, revision])
            try Task.checkCancellation()
            guard let saved = try Self.meetingPreparationPreference(db, occurrence: occurrence, mailAccountID: mailAccountID, threadID: threadID)
            else { throw MeetingPreparationStoreError.invalidPreference }
            return saved
        }
    }

    /// Restoring removes the override, allowing ordinary source discovery to apply again.
    public func restoreMeetingPreparationSource(occurrence: MeetingPreparationOccurrence, mailAccountID: String,
                                                 threadID: String, expectedRevision: String) async throws -> Bool {
        try Task.checkCancellation()
        try Self.validateMeetingPreparationSource(occurrence, mailAccountID: mailAccountID, threadID: threadID)
        return try await writer.write { db in
            try Task.checkCancellation()
            try Self.requireMeetingPreparationAccount(db, accountID: occurrence.eventAccountID)
            try Self.requireMeetingPreparationAccount(db, accountID: mailAccountID)
            guard let current = try Self.meetingPreparationPreference(db, occurrence: occurrence, mailAccountID: mailAccountID, threadID: threadID)
            else { return false }
            guard current.revision == expectedRevision else { throw MeetingPreparationStoreError.conflict }
            try db.execute(sql: """
                DELETE FROM meetingPreparationPreference WHERE eventAccountID = ? AND calendarID = ?
                    AND occurrenceKey = ? AND mailAccountID = ? AND threadID = ?
                """, arguments: [occurrence.eventAccountID, occurrence.calendarID, occurrence.identity.storageKey, mailAccountID, threadID])
            try Task.checkCancellation()
            return true
        }
    }
}

private extension AccountStore {
    static func meetingPreparationAccountAvailable(_ db: Database, accountID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM account WHERE id = ?
                AND NOT EXISTS(SELECT 1 FROM pendingAccountRemoval WHERE accountID = ?))
            """, arguments: [accountID, accountID]) ?? false
    }

    static func requireMeetingPreparationAccount(_ db: Database, accountID: String) throws {
        guard try meetingPreparationAccountAvailable(db, accountID: accountID) else { throw MeetingPreparationStoreError.unavailableAccount }
    }

    static func validateMeetingPreparationSource(_ occurrence: MeetingPreparationOccurrence, mailAccountID: String, threadID: String) throws {
        try occurrence.validate()
        guard [mailAccountID, threadID].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MeetingPreparationStoreError.invalidPreference
        }
    }

    static func meetingPreparationPreferences(_ db: Database, occurrence: MeetingPreparationOccurrence) throws -> [MeetingPreparationSourcePreference] {
        try Row.fetchAll(db, sql: """
            SELECT * FROM meetingPreparationPreference WHERE eventAccountID = ? AND calendarID = ? AND occurrenceKey = ?
                AND NOT EXISTS(SELECT 1 FROM pendingAccountRemoval p WHERE p.accountID = meetingPreparationPreference.mailAccountID)
            ORDER BY mailAccountID, threadID
            """, arguments: [occurrence.eventAccountID, occurrence.calendarID, occurrence.identity.storageKey])
            .map(decodeMeetingPreparationPreference)
    }

    static func meetingPreparationPreference(_ db: Database, occurrence: MeetingPreparationOccurrence,
                                              mailAccountID: String, threadID: String) throws -> MeetingPreparationSourcePreference? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM meetingPreparationPreference WHERE eventAccountID = ? AND calendarID = ?
                AND occurrenceKey = ? AND mailAccountID = ? AND threadID = ?
            """, arguments: [occurrence.eventAccountID, occurrence.calendarID, occurrence.identity.storageKey, mailAccountID, threadID])
            .map(decodeMeetingPreparationPreference)
    }

    static func decodeMeetingPreparationPreference(_ row: Row) throws -> MeetingPreparationSourcePreference {
        let payload: String = row["occurrence"]
        let occurrence = try JSONDecoder().decode(MeetingPreparationOccurrence.self, from: Data(payload.utf8))
        let mailAccountID: String = row["mailAccountID"], threadID: String = row["threadID"]
        let rawChoice: String = row["choice"], revision: String = row["revision"]
        let updatedAt: Date = row["updatedAt"]
        try validateMeetingPreparationSource(occurrence, mailAccountID: mailAccountID, threadID: threadID)
        guard occurrence.eventAccountID == (row["eventAccountID"] as String), occurrence.calendarID == (row["calendarID"] as String),
              occurrence.identity.storageKey == (row["occurrenceKey"] as String),
              let choice = MeetingPreparationSourceChoice(rawValue: rawChoice), !revision.isEmpty,
              updatedAt.timeIntervalSince1970.isFinite else { throw MeetingPreparationStoreError.invalidPreference }
        return MeetingPreparationSourcePreference(occurrence: occurrence, mailAccountID: mailAccountID,
            threadID: threadID, choice: choice, updatedAt: updatedAt, revision: revision)
    }
}
