import Foundation
import GmailAPI
import GRDB

/// Remote calendar mirrors and durable local work share transactions, but a
/// mirror rebuild never deletes proposals, source links or pending operations.
public struct CalendarStore: Sendable {
    let writer: any DatabaseWriter

    public static func open(at url: URL) throws -> CalendarStore {
        try CalendarStore(writer: DatabasePool(path: url.path(percentEncoded: false)))
    }
    public static func inMemory() throws -> CalendarStore { try CalendarStore(writer: DatabaseQueue()) }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        var migrator = DatabaseMigrator()
        migrator.registerMigration("calendar-v1") { db in
            try db.execute(sql: """
                CREATE TABLE calendarMirror (accountID TEXT NOT NULL, calendarID TEXT NOT NULL, payload TEXT NOT NULL,
                  PRIMARY KEY(accountID, calendarID));
                CREATE TABLE calendarEvent (accountID TEXT NOT NULL, calendarID TEXT NOT NULL, eventID TEXT NOT NULL,
                  iCalUID TEXT, payload TEXT NOT NULL, PRIMARY KEY(accountID, calendarID, eventID));
                CREATE INDEX calendarEvent_uid ON calendarEvent(accountID, calendarID, iCalUID);
                CREATE TABLE calendarSync (accountID TEXT NOT NULL, calendarID TEXT NOT NULL, syncToken TEXT,
                  generation INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0, lastSyncedAt DOUBLE,
                  PRIMARY KEY(accountID, calendarID));
                CREATE TABLE calendarWindow (accountID TEXT NOT NULL, calendarID TEXT NOT NULL, start DOUBLE NOT NULL,
                  end DOUBLE NOT NULL, revision INTEGER NOT NULL, fetchedAt DOUBLE NOT NULL, payload TEXT NOT NULL,
                  PRIMARY KEY(accountID, calendarID, start, end));
                CREATE TABLE calendarPreference (accountID TEXT NOT NULL, calendarID TEXT NOT NULL, payload TEXT NOT NULL,
                  PRIMARY KEY(accountID, calendarID));
                CREATE TABLE calendarOperation (id TEXT NOT NULL PRIMARY KEY, accountID TEXT NOT NULL,
                  calendarID TEXT NOT NULL, status TEXT NOT NULL, createdAt DOUBLE NOT NULL, payload TEXT NOT NULL);
                CREATE INDEX calendarOperation_status ON calendarOperation(accountID, status, createdAt);
                CREATE TABLE calendarSource (id TEXT NOT NULL PRIMARY KEY, accountID TEXT NOT NULL,
                  calendarID TEXT NOT NULL, eventID TEXT NOT NULL, messageID TEXT NOT NULL, payload TEXT NOT NULL);
                CREATE TABLE calendarSuggestion (id TEXT NOT NULL, accountID TEXT NOT NULL, threadID TEXT NOT NULL,
                  payload TEXT NOT NULL, PRIMARY KEY(accountID, id));
                """)
        }
        migrator.registerMigration("calendar-email-interpretation-v1") { db in
            try db.execute(sql: """
                CREATE TABLE calendarEmailInterpretation (
                  accountID TEXT NOT NULL, threadID TEXT NOT NULL, revision TEXT NOT NULL, payload BLOB NOT NULL,
                  PRIMARY KEY(accountID, threadID, revision))
                """)
        }
        try migrator.migrate(writer)
    }

    public func calendars(accountID: String) async throws -> [GoogleCalendarEntry] {
        try await writer.read { db in
            try Self.decodeRows(GoogleCalendarEntry.self, db: db,
                                sql: "SELECT payload FROM calendarMirror WHERE accountID = ? ORDER BY calendarID", arguments: [accountID])
        }
    }

    public func replaceCalendars(_ calendars: [GoogleCalendarEntry], accountID: String) async throws {
        try await writer.write { db in
            let old = try Self.decodeRows(GoogleCalendarEntry.self, db: db,
                sql: "SELECT payload FROM calendarMirror WHERE accountID = ?", arguments: [accountID])
            let existing = Set(old.map(\.id))
            let live = calendars.filter { $0.deleted != true }
            let removed = existing.subtracting(live.map(\.id))
            let detailDowngrades = Set(old.filter { previous in
                guard previous.canReadDetails else { return false }
                guard let current = live.first(where: { $0.id == previous.id }) else { return true }
                return !current.canReadDetails || current.accessRole != previous.accessRole
            }.map(\.id))
            let writeDowngrades = Set(old.filter { previous in
                previous.canWrite && live.first(where: { $0.id == previous.id })?.canWrite != true
            }.map(\.id))
            for id in removed {
                try db.execute(sql: "DELETE FROM calendarMirror WHERE accountID = ? AND calendarID = ?", arguments: [accountID, id])
            }
            for id in removed.union(detailDowngrades) {
                try Self.resetRemote(db, accountID: accountID, calendarID: id)
            }
            for id in removed.union(writeDowngrades) {
                let rows: [CalendarOperation] = try Self.decodeRows(CalendarOperation.self, db: db,
                    sql: "SELECT payload FROM calendarOperation WHERE accountID = ? AND calendarID = ? AND status IN ('proposed','queued','running')",
                    arguments: [accountID, id])
                for var operation in rows {
                    operation.status = .failed; operation.errorMessage = "Calendar access was removed."
                    try Self.putOperation(operation, db: db)
                }
            }
            for entry in live {
                try db.execute(sql: "INSERT OR REPLACE INTO calendarMirror VALUES (?, ?, ?)",
                               arguments: [accountID, entry.id, try Self.encode(entry)])
            }
        }
    }

    public func syncState(accountID: String, calendarID: String) async throws -> CalendarSyncState {
        try await writer.read { try Self.state($0, accountID: accountID, calendarID: calendarID) }
    }

    public func resetRemoteCalendar(accountID: String, calendarID: String, expected: CalendarSyncState? = nil) async throws {
        try await writer.write { db in
            if let expected {
                let state = try Self.state(db, accountID: accountID, calendarID: calendarID)
                guard state.generation == expected.generation, state.revision == expected.revision,
                      state.syncToken == expected.syncToken else { throw CalendarStoreError.staleGeneration }
            }
            try Self.resetRemote(db, accountID: accountID, calendarID: calendarID)
        }
    }

    /// A complete page sequence commits together with its cursor. Requests that
    /// started before a write or reset cannot replace that newer state.
    public func applyEventSync(_ events: [GoogleCalendarEvent], accountID: String, calendarID: String,
                               token: String?, replacing: Bool, expected: CalendarSyncState, at date: Date = .now) async throws {
        try await writer.write { db in
            let state = try Self.state(db, accountID: accountID, calendarID: calendarID)
            guard state.generation == expected.generation, state.revision == expected.revision,
                  state.syncToken == expected.syncToken else { throw CalendarStoreError.staleGeneration }
            if replacing {
                try db.execute(sql: "DELETE FROM calendarEvent WHERE accountID = ? AND calendarID = ?", arguments: [accountID, calendarID])
            }
            for event in events { try Self.putEvent(event, accountID: accountID, calendarID: calendarID, db: db) }
            let changed = replacing || !events.isEmpty
            if changed {
                // Occurrence windows may contain details that a changed event no
                // longer exposes. They cannot be offered as an offline fallback.
                try db.execute(sql: "DELETE FROM calendarWindow WHERE accountID = ? AND calendarID = ?", arguments: [accountID, calendarID])
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO calendarSync(accountID,calendarID,syncToken,generation,revision,lastSyncedAt)
                VALUES(?,?,?,?,?,?)
                """, arguments: [accountID, calendarID, token, state.generation, state.revision + (changed ? 1 : 0), date.timeIntervalSince1970])
        }
    }

    public func event(accountID: String, calendarID: String, eventID: String) async throws -> GoogleCalendarEvent? {
        try await writer.read { db in
            try Self.decodeRows(GoogleCalendarEvent.self, db: db,
                sql: "SELECT payload FROM calendarEvent WHERE accountID = ? AND calendarID = ? AND eventID = ?",
                arguments: [accountID, calendarID, eventID]).first
        }
    }

    public func events(accountID: String, calendarID: String, iCalUID: String? = nil) async throws -> [GoogleCalendarEvent] {
        try await writer.read { db in
            let filter = iCalUID == nil ? "" : " AND iCalUID = ?"
            var arguments: StatementArguments = [accountID, calendarID]
            if let iCalUID { arguments += [iCalUID] }
            return try Self.decodeRows(GoogleCalendarEvent.self, db: db,
                sql: "SELECT payload FROM calendarEvent WHERE accountID = ? AND calendarID = ?" + filter, arguments: arguments)
        }
    }

    public func cacheEvent(_ event: GoogleCalendarEvent, accountID: String, calendarID: String,
                           expected: CalendarSyncState? = nil) async throws {
        try await writer.write { db in
            if let expected {
                let state = try Self.state(db, accountID: accountID, calendarID: calendarID)
                guard state.generation == expected.generation, state.revision == expected.revision else {
                    throw CalendarStoreError.staleGeneration
                }
            }
            try Self.putEvent(event, accountID: accountID, calendarID: calendarID, db: db)
        }
    }

    public func cachedOccurrences(accountID: String, calendarID: String, start: Date, end: Date) async throws -> CalendarOccurrenceResult {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM calendarWindow WHERE accountID = ? AND calendarID = ? AND start <= ? AND end >= ?
                ORDER BY fetchedAt DESC LIMIT 1
                """, arguments: [accountID, calendarID, start.timeIntervalSince1970, end.timeIntervalSince1970]) else {
                return CalendarOccurrenceResult(events: [], isStale: true, isComplete: false)
            }
            let data: String = row["payload"]
            let events = try Self.decode([GoogleCalendarEvent].self, data)
            let revision: Int = row["revision"]
            let fetchedAt: Double = row["fetchedAt"]
            let state = try Self.state(db, accountID: accountID, calendarID: calendarID)
            let calendar = try Self.decodeRows(GoogleCalendarEntry.self, db: db,
                sql: "SELECT payload FROM calendarMirror WHERE accountID = ? AND calendarID = ?",
                arguments: [accountID, calendarID]).first
            let timeZone = calendar?.timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            return CalendarOccurrenceResult(events: events.filter {
                guard let eventStart = $0.start?.resolvedDate(fallbackTimeZone: timeZone),
                      let eventEnd = $0.end?.resolvedDate(fallbackTimeZone: timeZone) else { return false }
                return !$0.isCancelled && eventStart < end && eventEnd > start
            }, fetchedAt: Date(timeIntervalSince1970: fetchedAt), isStale: revision != state.revision, isComplete: true)
        }
    }

    public func saveOccurrences(_ events: [GoogleCalendarEvent], accountID: String, calendarID: String,
                                start: Date, end: Date, expected: CalendarSyncState, at date: Date = .now) async throws {
        try await writer.write { db in
            let state = try Self.state(db, accountID: accountID, calendarID: calendarID)
            guard state.generation == expected.generation, state.revision == expected.revision else { throw CalendarStoreError.staleGeneration }
            try db.execute(sql: "INSERT OR REPLACE INTO calendarWindow VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [accountID, calendarID, start.timeIntervalSince1970, end.timeIntervalSince1970,
                            state.revision, date.timeIntervalSince1970, try Self.encode(events)])
        }
    }

    public func preferences(accountID: String) async throws -> [CalendarPreferences] {
        try await writer.read { db in try Self.decodeRows(CalendarPreferences.self, db: db,
            sql: "SELECT payload FROM calendarPreference WHERE accountID = ?", arguments: [accountID]) }
    }

    public func savePreferences(_ preferences: CalendarPreferences) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO calendarPreference VALUES (?, ?, ?)",
                           arguments: [preferences.accountID, preferences.calendarID, try Self.encode(preferences)])
        }
    }

    public func operation(id: String) async throws -> CalendarOperation? {
        try await writer.read { db in try Self.decodeRows(CalendarOperation.self, db: db,
            sql: "SELECT payload FROM calendarOperation WHERE id = ?", arguments: [id]).first }
    }

    public func operation(accountID: String, id: String) async throws -> CalendarOperation? {
        guard let value = try await operation(id: id), value.accountID == accountID else { return nil }
        return value
    }

    public func cancelProposals(accountID: String, calendarID: String? = nil) async throws {
        try await writer.write { db in
            var sql = "SELECT payload FROM calendarOperation WHERE accountID = ? AND status = 'proposed'"
            var arguments: StatementArguments = [accountID]
            if let calendarID { sql += " AND calendarID = ?"; arguments += [calendarID] }
            let proposals = try Self.decodeRows(CalendarOperation.self, db: db, sql: sql, arguments: arguments)
            for var proposal in proposals {
                proposal.status = .cancelled; proposal.updatedAt = .now
                try Self.putOperation(proposal, db: db)
            }
        }
    }

    public func operations(accountID: String) async throws -> [CalendarOperation] {
        try await writer.read { db in try Self.decodeRows(CalendarOperation.self, db: db,
            sql: "SELECT payload FROM calendarOperation WHERE accountID = ? ORDER BY createdAt, id", arguments: [accountID]) }
    }

    public func saveOperation(_ operation: CalendarOperation) async throws {
        try await writer.write { try Self.putOperation(operation, db: $0) }
    }

    public func enqueueOperation(_ operation: CalendarOperation) async throws -> CalendarOperation {
        try await writer.write { db in
            guard operation.status == .queued else { throw CalendarStoreError.invalidRecord }
            if let existing = try Self.operationForSuggestion(matching: operation, db: db) { return existing }
            if let existing = try Self.pendingResponse(matching: operation, db: db) { return existing }
            try Self.putOperation(operation, db: db)
            try Self.bindSuggestion(to: operation, db: db)
            return operation
        }
    }

    public func approveOperation(accountID: String, id: String) async throws {
        try await writer.write { db in
            guard var operation = try Self.decodeRows(CalendarOperation.self, db: db,
                sql: "SELECT payload FROM calendarOperation WHERE accountID = ? AND id = ?", arguments: [accountID, id]).first,
                  operation.status == .proposed else { throw CalendarStoreError.invalidRecord }
            let alreadyQueued = try Self.pendingResponse(matching: operation, db: db) != nil || Self.operationForSuggestion(matching: operation, db: db) != nil
            operation.status = alreadyQueued ? .cancelled : .queued
            operation.updatedAt = .now
            try Self.putOperation(operation, db: db)
            if operation.status == .queued { try Self.bindSuggestion(to: operation, db: db) }
        }
    }

    public func requeueOperation(accountID: String, id: String) async throws {
        try await writer.write { db in
            guard var operation = try Self.decodeRows(CalendarOperation.self, db: db,
                sql: "SELECT payload FROM calendarOperation WHERE accountID = ? AND id = ?", arguments: [accountID, id]).first,
                  operation.status == .failed || operation.status == .queued else { throw CalendarStoreError.invalidRecord }
            if let existing = try Self.pendingResponse(matching: operation, db: db), existing.id != operation.id {
                throw CalendarStoreError.responseAlreadyPending
            }
            if try Self.operationForSuggestion(matching: operation, db: db) != nil { throw CalendarStoreError.invalidRecord }
            operation.status = .queued; operation.errorMessage = nil; operation.updatedAt = .now
            try Self.putOperation(operation, db: db)
            try Self.bindSuggestion(to: operation, db: db)
        }
    }

    /// Claim and cancellation compete in the same transaction. A queued row
    /// cancelled while another operation awaits Google cannot be sent later.
    public func claimOperation(accountID: String, id: String) async throws -> CalendarOperation? {
        try await writer.write { db in
            guard var operation = try Self.decodeRows(CalendarOperation.self, db: db,
                sql: "SELECT payload FROM calendarOperation WHERE accountID = ? AND id = ?", arguments: [accountID, id]).first,
                  operation.status == .queued || operation.status == .running else { return nil }
            operation.status = .running; operation.attempts += 1; operation.updatedAt = .now
            try Self.putOperation(operation, db: db)
            return operation
        }
    }

    @discardableResult
    public func cancelOperation(accountID: String, id: String) async throws -> Bool {
        try await writer.write { db in
            guard var operation = try Self.decodeRows(CalendarOperation.self, db: db,
                sql: "SELECT payload FROM calendarOperation WHERE accountID = ? AND id = ?", arguments: [accountID, id]).first,
                  operation.status == .proposed || (operation.status == .queued && operation.attempts == 0) else { return false }
            operation.status = .cancelled; operation.updatedAt = .now
            try Self.putOperation(operation, db: db)
            return true
        }
    }

    /// Replacing a reviewed proposal is atomic with cancelling the previous one.
    /// An uncertain or partly completed write must be reconciled, not replaced.
    public func replaceOperation(accountID: String, id: String, with replacement: CalendarOperation) async throws {
        try await writer.write { db in
            guard replacement.accountID == accountID, replacement.id != id,
                  replacement.status == .queued || replacement.status == .proposed,
                  var old = try Self.decodeRows(CalendarOperation.self, db: db,
                    sql: "SELECT payload FROM calendarOperation WHERE accountID = ? AND id = ?", arguments: [accountID, id]).first,
                  old.completedStep == 0,
                  (old.status == .conflicted || (old.attempts == 0 && [.proposed, .queued, .failed].contains(old.status))) else {
                throw CalendarStoreError.invalidRecord
            }
            var resolved = replacement
            if let previousSource = old.sourceSuggestionID {
                guard replacement.sourceSuggestionID == nil || replacement.sourceSuggestionID == previousSource else { throw CalendarStoreError.invalidRecord }
                resolved.sourceSuggestionID = previousSource
            }
            old.status = .cancelled; old.updatedAt = .now
            try Self.putOperation(old, db: db)
            if try Self.pendingResponse(matching: resolved, db: db) != nil { throw CalendarStoreError.responseAlreadyPending }
            if try Self.operationForSuggestion(matching: resolved, db: db) != nil { throw CalendarStoreError.invalidRecord }
            try Self.putOperation(resolved, db: db)
            if resolved.status == .queued { try Self.bindSuggestion(to: resolved, db: db) }
        }
    }

    /// The event response and operation receipt commit together, so a crash
    /// cannot show an unsent operation after caching its successful response.
    public func finishOperation(_ operation: CalendarOperation, event: GoogleCalendarEvent?, deletedEventID: String? = nil) async throws {
        try await writer.write { db in
            let calendarID: String
            if case .move(_, let destination, _) = operation.mutation { calendarID = destination }
            else { calendarID = operation.calendarID }
            if let event { try Self.putEvent(event, accountID: operation.accountID, calendarID: calendarID, db: db) }
            if let deletedEventID {
                try db.execute(sql: "DELETE FROM calendarEvent WHERE accountID = ? AND calendarID = ? AND eventID = ?",
                               arguments: [operation.accountID, operation.calendarID, deletedEventID])
            }
            try Self.bumpRevision(db, accountID: operation.accountID, calendarID: operation.calendarID)
            if calendarID != operation.calendarID { try Self.bumpRevision(db, accountID: operation.accountID, calendarID: calendarID) }
            try Self.putOperation(operation, db: db)
        }
    }

    public func sourceLinks(accountID: String, calendarID: String? = nil, eventID: String? = nil) async throws -> [CalendarSourceLink] {
        try await writer.read { db in
            var sql = "SELECT payload FROM calendarSource WHERE accountID = ?"
            var arguments: StatementArguments = [accountID]
            if let calendarID { sql += " AND calendarID = ?"; arguments += [calendarID] }
            if let eventID { sql += " AND eventID = ?"; arguments += [eventID] }
            return try Self.decodeRows(CalendarSourceLink.self, db: db, sql: sql, arguments: arguments)
        }
    }

    public func saveSourceLink(_ source: CalendarSourceLink) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO calendarSource VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [source.id, source.accountID, source.calendarID, source.eventID, source.messageID, try Self.encode(source)])
        }
    }

    public func suggestions(accountID: String, threadID: String) async throws -> [CalendarSuggestionRecord] {
        try await writer.read { db in try Self.decodeRows(CalendarSuggestionRecord.self, db: db,
            sql: "SELECT payload FROM calendarSuggestion WHERE accountID = ? AND threadID = ?", arguments: [accountID, threadID]) }
    }

    public func saveSuggestion(_ suggestion: CalendarSuggestionRecord, preservingCorrections: Bool = true) async throws {
        try await writer.write { db in
            if preservingCorrections, let old = try Self.decodeRows(CalendarSuggestionRecord.self, db: db,
                sql: "SELECT payload FROM calendarSuggestion WHERE accountID = ? AND id = ?", arguments: [suggestion.accountID, suggestion.id]).first,
               old.isUserEdited || old.isDismissed || old.operationID != nil { return }
            try db.execute(sql: "INSERT OR REPLACE INTO calendarSuggestion VALUES (?, ?, ?, ?)",
                           arguments: [suggestion.id, suggestion.accountID, suggestion.threadID, try Self.encode(suggestion)])
        }
    }

    public func deleteAccountData(accountID: String) async throws {
        try await writer.write { db in
            for table in Self.accountTables { try db.execute(sql: "DELETE FROM \(table) WHERE accountID = ?", arguments: [accountID]) }
        }
    }

    public func accountIDs() async throws -> Set<String> {
        try await writer.read { db in
            try String.fetchSet(db, sql: Self.accountTables.map { "SELECT accountID FROM \($0)" }.joined(separator: " UNION "))
        }
    }

    static let accountTables = ["calendarMirror", "calendarEvent", "calendarSync", "calendarWindow", "calendarPreference", "calendarOperation", "calendarSource", "calendarSuggestion", "calendarEmailInterpretation"]

    static func state(_ db: Database, accountID: String, calendarID: String) throws -> CalendarSyncState {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM calendarSync WHERE accountID = ? AND calendarID = ?", arguments: [accountID, calendarID]) else { return CalendarSyncState() }
        let timestamp: Double? = row["lastSyncedAt"]
        return CalendarSyncState(syncToken: row["syncToken"], generation: row["generation"], revision: row["revision"],
                                 lastSyncedAt: timestamp.map(Date.init(timeIntervalSince1970:)))
    }

    static func resetRemote(_ db: Database, accountID: String, calendarID: String) throws {
        let state = try state(db, accountID: accountID, calendarID: calendarID)
        for table in ["calendarEvent", "calendarWindow"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE accountID = ? AND calendarID = ?", arguments: [accountID, calendarID])
        }
        try db.execute(sql: "INSERT OR REPLACE INTO calendarSync VALUES (?, ?, NULL, ?, ?, NULL)",
                       arguments: [accountID, calendarID, state.generation + 1, state.revision + 1])
    }

    static func bumpRevision(_ db: Database, accountID: String, calendarID: String) throws {
        try db.execute(sql: """
            INSERT INTO calendarSync(accountID,calendarID,generation,revision) VALUES(?,?,0,1)
            ON CONFLICT(accountID,calendarID) DO UPDATE SET revision = revision + 1
            """, arguments: [accountID, calendarID])
        try db.execute(sql: "DELETE FROM calendarWindow WHERE accountID = ? AND calendarID = ?", arguments: [accountID, calendarID])
    }

    static func putEvent(_ event: GoogleCalendarEvent, accountID: String, calendarID: String, db: Database) throws {
        guard !event.id.isEmpty else { throw CalendarStoreError.invalidRecord }
        if event.isCancelled && event.recurringEventId == nil {
            try db.execute(sql: "DELETE FROM calendarEvent WHERE accountID = ? AND calendarID = ? AND eventID = ?", arguments: [accountID, calendarID, event.id])
        } else {
            try db.execute(sql: "INSERT OR REPLACE INTO calendarEvent VALUES (?, ?, ?, ?, ?)",
                           arguments: [accountID, calendarID, event.id, event.iCalUID, try encode(event)])
        }
    }

    static func putOperation(_ operation: CalendarOperation, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO calendarOperation VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [operation.id, operation.accountID, operation.calendarID, operation.status.rawValue,
                                   operation.createdAt.timeIntervalSince1970, try encode(operation)])
    }

    static func pendingResponse(matching operation: CalendarOperation, db: Database) throws -> CalendarOperation? {
        guard case .respond(let eventID, let response, _) = operation.mutation else { return nil }
        let pending = try decodeRows(CalendarOperation.self, db: db,
            sql: "SELECT payload FROM calendarOperation WHERE accountID = ? AND calendarID = ? AND status IN ('queued','running')",
            arguments: [operation.accountID, operation.calendarID])
        for existing in pending where existing.id != operation.id {
            guard case .respond(let target, let answer, _) = existing.mutation, target == eventID else { continue }
            guard answer == response else { throw CalendarStoreError.responseAlreadyPending }
            return existing
        }
        return nil
    }

    static func encode(_ value: some Encodable) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try JSONDecoder().decode(type, from: Data(value.utf8)) }
    static func decodeRows<T: Decodable>(_ type: T.Type, db: Database, sql: String, arguments: StatementArguments) throws -> [T] {
        try String.fetchAll(db, sql: sql, arguments: arguments).map { try decode(type, $0) }
    }
}
