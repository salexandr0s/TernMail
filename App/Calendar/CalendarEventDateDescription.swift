import Foundation

/// Provider all-day ranges end at the start of the following calendar day.
enum CalendarEventDateDescription {
    static func text(start: Date, end: Date, isAllDay: Bool, calendar: Calendar) -> String {
        let style: Date.FormatStyle = isAllDay ? .dateTime.month(.wide).day().year() : .dateTime.month(.wide).day().year().hour().minute()
        let first = CalendarLayout.format(start, style: style, calendar: calendar)
        let last = isAllDay ? max(start, calendar.date(byAdding: .day, value: -1, to: end) ?? start) : end
        if isAllDay, calendar.isDate(start, inSameDayAs: last) { return first }
        return "\(first) – \(CalendarLayout.format(last, style: style, calendar: calendar))"
    }

    /// What a chip adds to its tooltip and VoiceOver label after the title and
    /// the calendar. Chips use the system calendar in the time zone Calendar shows.
    static func chip(_ event: CalendarDisplayEvent, timeZone: TimeZone) -> String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        var parts = [text(start: event.start, end: event.end, isAllDay: event.isAllDay, calendar: calendar)]
        if event.isAllDay { parts.append(String(localized: "All day")) }
        if event.isPending { parts.append(String(localized: "Pending sync")) }
        return parts.joined(separator: ", ")
    }

    /// The start and end a timeline card adds to its tooltip and VoiceOver label.
    static func cardRange(_ event: CalendarDisplayEvent, calendar: Calendar) -> String {
        CalendarLayout.format(event.start, style: .dateTime.month().day().hour().minute(), calendar: calendar)
            + " – " + CalendarLayout.format(event.end, style: .dateTime.month().day().hour().minute(), calendar: calendar)
            + (event.isPending ? ", pending sync" : "")
    }

    /// The start time on a timeline card's second line.
    static func cardStart(_ event: CalendarDisplayEvent, calendar: Calendar) -> String {
        CalendarLayout.format(event.start, style: .dateTime.hour().minute(), calendar: calendar)
    }
}
