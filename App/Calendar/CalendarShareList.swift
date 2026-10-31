import Foundation
import Observation

/// The people one calendar is shared with, as Calendar settings shows them.
/// The list remembers which calendar it belongs to, so a read that returns
/// after the user picked another calendar is dropped instead of showing that
/// calendar's people under the new one.
@MainActor
@Observable
final class CalendarShareList {
    /// The calendar whose people the list holds.
    private(set) var calendarID: String?
    private var people: [CalendarShare] = []
    @ObservationIgnored private var latestRead = 0

    /// The people to show under `calendar`: empty unless the list is that calendar's.
    func shares(for calendar: CalendarDisplayCalendar) -> [CalendarShare] {
        calendar.id == calendarID ? people : []
    }

    /// Points the list at another calendar. The old people go at once, and a
    /// read still running for the old calendar is dropped when it returns.
    func select(_ calendarID: String?) {
        guard calendarID != self.calendarID else { return }
        self.calendarID = calendarID
        people = []
        latestRead += 1
    }

    /// Reads `calendar`'s people and shows them, unless by the time the read
    /// returns the list belongs to another calendar or a newer read has started.
    /// Errors are thrown only while the read is still current, so a failure for
    /// a calendar the user has left never reaches the screen. A calendar the
    /// list doesn't belong to isn't read at all.
    func reload(_ calendar: CalendarDisplayCalendar,
                using read: @MainActor (CalendarDisplayCalendar) async throws -> [CalendarShare]) async throws {
        guard calendar.id == calendarID else { return }
        latestRead += 1
        let request = latestRead
        do {
            let result = try await read(calendar)
            guard request == latestRead, !Task.isCancelled else { return }
            people = result
        } catch {
            guard request == latestRead, !Task.isCancelled else { return }
            throw error
        }
    }
}
