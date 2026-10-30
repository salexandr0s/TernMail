import Foundation
import GRDB

extension AccountStore {
    /// Calendar visibility and assistant consent belong to config.sqlite, so a
    /// disposable Google mirror rebuild never resets the user's choices.
    public func calendarPreferences(accountID: String) async throws -> [CalendarPreferences] {
        try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM calendarPreference WHERE accountID = ? ORDER BY calendarID",
                                arguments: [accountID]).map {
                try JSONDecoder().decode(CalendarPreferences.self, from: Data($0.utf8))
            }
        }
    }

    /// The account foreign key prevents a delayed save from restoring settings
    /// after account removal. Saving an existing account preserves its settings.
    public func saveCalendarPreferences(_ preferences: CalendarPreferences) async throws {
        guard !preferences.accountID.isEmpty, !preferences.calendarID.isEmpty else {
            throw CalendarPreferencesError.missingIdentity
        }
        let payload = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO calendarPreference (accountID, calendarID, payload) VALUES (?, ?, ?)
                ON CONFLICT (accountID, calendarID) DO UPDATE SET payload = excluded.payload
                """, arguments: [preferences.accountID, preferences.calendarID, payload])
        }
    }
}

public enum CalendarPreferencesError: Error, Sendable, Equatable {
    case missingIdentity
}
