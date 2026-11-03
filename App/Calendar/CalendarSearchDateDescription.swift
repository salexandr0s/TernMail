import Foundation

/// Provider all-day ranges end at the start of the following calendar day.
enum CalendarSearchDateDescription {
    static func text(start: Date, end: Date, isAllDay: Bool, calendar: Calendar) -> String {
        let style: Date.FormatStyle = isAllDay ? .dateTime.month(.wide).day().year() : .dateTime.month(.wide).day().year().hour().minute()
        let first = CalendarLayout.format(start, style: style, calendar: calendar)
        let last = isAllDay ? max(start, calendar.date(byAdding: .day, value: -1, to: end) ?? start) : end
        if isAllDay, calendar.isDate(start, inSameDayAs: last) { return first }
        return "\(first) – \(CalendarLayout.format(last, style: style, calendar: calendar))"
    }
}
