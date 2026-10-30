import Foundation
import GRDB
import MessageContent

extension CacheTransaction {
    /// Includes every VEVENT in a message, including exceptions retained in the wrapper.
    public func calendarInvitations(accountID: String, threadID: String? = nil) throws -> [MessageCalendarRecord] {
        let records: [MessageCalendarRecord]
        if let threadID {
            records = try MessageCalendarRecord.fetchAll(db, sql: """
                SELECT messageCalendar.* FROM messageCalendar JOIN message
                ON message.accountID = messageCalendar.accountID AND message.id = messageCalendar.messageID
                WHERE messageCalendar.accountID = ? AND message.threadID = ?
                """, arguments: [accountID, threadID])
        } else {
            records = try MessageCalendarRecord.filter(Column("accountID") == accountID).fetchAll(db)
        }
        return records.flatMap { record in
            ([record.invitation] + (record.invitation.additionalEvents ?? [])).map {
                var invitation = $0
                invitation.additionalEvents = nil
                return MessageCalendarRecord(accountID: accountID, messageID: record.messageID, invitation: invitation)
            }
        }
    }

    public func deleteMessageCalendar(messageID: String, accountID: String) throws {
        try db.execute(sql: "DELETE FROM messageCalendar WHERE accountID = ? AND messageID = ?", arguments: [accountID, messageID])
    }
}

extension CalendarStore {
    /// The candidate and queue receipt are one commit, including the ordinary date-detection
    /// path that has no remote UID to reconcile after a crash.
    static func operationForSuggestion(matching operation: CalendarOperation, db: Database) throws -> CalendarOperation? {
        guard let id = operation.sourceSuggestionID else { return nil }
        guard let source = try Self.decodeRows(CalendarSuggestionRecord.self, db: db,
            sql: "SELECT payload FROM calendarSuggestion WHERE accountID = ? AND id = ?", arguments: [operation.accountID, id]).first else {
            throw CalendarStoreError.invalidRecord
        }
        guard let previousID = source.operationID, previousID != operation.id else { return nil }
        guard let previous = try Self.decodeRows(CalendarOperation.self, db: db,
            sql: "SELECT payload FROM calendarOperation WHERE accountID = ? AND id = ?", arguments: [operation.accountID, previousID]).first else {
            throw CalendarStoreError.invalidRecord
        }
        return previous.status == .cancelled ? nil : previous
    }

    static func bindSuggestion(to operation: CalendarOperation, db: Database) throws {
        guard let id = operation.sourceSuggestionID else { return }
        guard var source = try Self.decodeRows(CalendarSuggestionRecord.self, db: db,
            sql: "SELECT payload FROM calendarSuggestion WHERE accountID = ? AND id = ?", arguments: [operation.accountID, id]).first else {
            throw CalendarStoreError.invalidRecord
        }
        source.operationID = operation.id
        source.isUserEdited = true
        switch operation.mutation {
        case .create(let event), .importEvent(let event), .importSeries(let event, _): source.event = event
        case .update(_, let fields, _):
            for (key, value) in fields { source.event.rawValue[key] = value == .null ? nil : value }
        default: break
        }
        try db.execute(sql: "UPDATE calendarSuggestion SET payload = ? WHERE accountID = ? AND id = ?",
            arguments: [try Self.encode(source), source.accountID, source.id])
    }

    public func emailInterpretation(accountID: String, threadID: String, revision: String) async throws -> Data? {
        try await writer.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM calendarEmailInterpretation WHERE accountID = ? AND threadID = ? AND revision = ?",
                arguments: [accountID, threadID, revision])
        }
    }

    /// Opaque, bounded application JSON. An encoded empty result is a completed interpretation too.
    public func saveEmailInterpretation(_ payload: Data, accountID: String, threadID: String, revision: String) async throws {
        guard payload.count <= 1_000_000 else { throw CalendarStoreError.invalidRecord }
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM calendarEmailInterpretation WHERE accountID = ? AND threadID = ?", arguments: [accountID, threadID])
            try db.execute(sql: "INSERT INTO calendarEmailInterpretation VALUES (?, ?, ?, ?)", arguments: [accountID, threadID, revision, payload])
        }
    }
    public func acceptedEmailSuggestions(accountID: String) async throws -> [CalendarSuggestionRecord] {
        try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM calendarSuggestion WHERE accountID = ?", arguments: [accountID])
                .map { try JSONDecoder().decode(CalendarSuggestionRecord.self, from: Data($0.utf8)) }
                .filter { $0.operationID != nil }
        }
    }
    public func suggestion(id: String) async throws -> CalendarSuggestionRecord? {
        try await writer.read { db in
            guard let payload = try String.fetchOne(db, sql: "SELECT payload FROM calendarSuggestion WHERE id = ? LIMIT 1", arguments: [id]) else { return nil }
            return try JSONDecoder().decode(CalendarSuggestionRecord.self, from: Data(payload.utf8))
        }
    }
}
