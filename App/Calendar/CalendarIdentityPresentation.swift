import SwiftUI

/// Calendar names resolved once for the event views in a calendar workspace.
struct CalendarIdentityPresentation: Equatable, Sendable {
    private let titlesByKey: [String: String]

    init(calendars: [CalendarDisplayCalendar]) {
        let titleCounts = Dictionary(grouping: calendars, by: \.title).mapValues(\.count)
        var titles: [String: String] = [:]
        for calendar in calendars {
            titles[calendar.id] = titleCounts[calendar.title, default: 0] > 1 && !calendar.accountName.isEmpty
                ? String(localized: "\(calendar.title) (\(calendar.accountName))")
                : calendar.title
        }
        titlesByKey = titles
    }

    func title(for calendarKey: String) -> String {
        titlesByKey[calendarKey] ?? String(localized: "Calendar")
    }
}

extension EnvironmentValues {
    @Entry var calendarIdentities = CalendarIdentityPresentation(calendars: [])
}
