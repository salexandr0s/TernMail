import Foundation
import GmailAPI

/// A proposed interval. All-day ends are exclusive, just like Google's API.
struct CalendarEventRange: Equatable {
    var start: Date
    var end: Date
    var isAllDay: Bool

    init(start: Date, end: Date, isAllDay: Bool) {
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }

    init(_ event: CalendarDisplayEvent) {
        self.init(start: event.start, end: event.end, isAllDay: event.isAllDay)
    }

    func applying(to event: GoogleCalendarEvent, calendar: Calendar) -> GoogleCalendarEvent {
        var result = event
        let startZone = isAllDay ? calendar.timeZone : TimeZone(identifier: event.start?.timeZone ?? "") ?? calendar.timeZone
        let endZone = isAllDay ? calendar.timeZone : TimeZone(identifier: event.end?.timeZone ?? "") ?? startZone
        if event.start?.resolvedDate(fallbackTimeZone: calendar.timeZone) != start || event.start?.isAllDay != isAllDay {
            result.start = CalendarDateTime(date: start, timeZone: startZone, allDay: isAllDay)
        }
        if event.end?.resolvedDate(fallbackTimeZone: calendar.timeZone) != end || event.end?.isAllDay != isAllDay {
            result.end = CalendarDateTime(date: end, timeZone: endZone, allDay: isAllDay)
        }
        return result
    }
}

enum CalendarInteraction {
    static let snapMinutes = 15

    /// Rounds `date` to a quarter hour of its day's real time, so a time in the
    /// hour the clocks repeat stays in the pass it was in.
    static func snapped(_ date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let minutes = (date.timeIntervalSince(day) / 60).rounded(.down)
        let step = Double(snapMinutes)
        return day.addingTimeInterval((minutes / step).rounded() * step * 60)
    }

    static func selection(from anchor: Date, to target: Date, allDay: Bool, calendar: Calendar) -> CalendarEventRange {
        if allDay {
            let start = calendar.startOfDay(for: min(anchor, target))
            let last = calendar.startOfDay(for: max(anchor, target))
            let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
            return CalendarEventRange(start: start, end: end, isAllDay: true)
        }
        let start = min(anchor, target)
        let end = max(max(anchor, target), start.addingTimeInterval(Double(snapMinutes * 60)))
        return CalendarEventRange(start: start, end: end, isAllDay: false)
    }

    static func moving(_ event: CalendarDisplayEvent, to proposedStart: Date, allDay: Bool? = nil,
                       calendar: Calendar) -> CalendarEventRange {
        let targetAllDay = allDay ?? event.isAllDay
        let start = targetAllDay ? calendar.startOfDay(for: proposedStart) : proposedStart
        let end: Date
        if targetAllDay {
            let oldStart = calendar.startOfDay(for: event.start)
            // Midnight is an exclusive boundary, not an additional occupied day.
            let lastDay = calendar.startOfDay(for: max(event.start, event.end.addingTimeInterval(-1)))
            let dayCount = max(1, (calendar.dateComponents([.day], from: oldStart, to: lastDay).day ?? 0) + 1)
            end = calendar.date(byAdding: .day, value: dayCount, to: start) ?? start
        } else {
            let duration = event.isAllDay ? 3600 : max(60, event.end.timeIntervalSince(event.start))
            end = start.addingTimeInterval(duration)
        }
        return CalendarEventRange(start: start, end: end, isAllDay: targetAllDay)
    }

    /// Where a drag in the hours puts `event`: it keeps its real-time offset from
    /// the point it was grabbed at, so after the clocks go back it can land in
    /// either pass of the repeated hour. An all-day event starts at the pointer.
    static func dragging(_ event: CalendarDisplayEvent, from anchor: Date, to target: Date,
                         calendar: Calendar) -> CalendarEventRange {
        let candidate = event.isAllDay ? target : event.start.addingTimeInterval(target.timeIntervalSince(anchor))
        let start = candidate == event.start && !event.isAllDay ? event.start : snapped(candidate, calendar: calendar)
        return moving(event, to: start, allDay: false, calendar: calendar)
    }

    /// Month/all-day moves keep the day under the pointer attached to the pointer.
    static func moving(_ event: CalendarDisplayEvent, from visibleDay: Date, to targetDay: Date,
                       calendar: Calendar) -> CalendarEventRange {
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: visibleDay),
                                             to: calendar.startOfDay(for: targetDay)).day ?? 0
        let start = calendar.date(byAdding: .day, value: offset, to: event.start) ?? event.start
        return moving(event, to: start, calendar: calendar)
    }

    static func resizing(_ event: CalendarDisplayEvent, to date: Date, startEdge: Bool,
                         calendar: Calendar) -> CalendarEventRange {
        var range = CalendarEventRange(event)
        if event.isAllDay {
            let day = calendar.startOfDay(for: date)
            if startEdge {
                let lastStart = calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.start
                range.start = min(day, lastStart)
            } else {
                let end = calendar.date(byAdding: .day, value: 1, to: day) ?? event.end
                let minimumEnd = calendar.date(byAdding: .day, value: 1, to: event.start) ?? event.end
                range.end = max(end, minimumEnd)
            }
        } else if startEdge {
            range.start = min(date, event.end.addingTimeInterval(-Double(snapMinutes * 60)))
        } else {
            range.end = max(date, event.start.addingTimeInterval(Double(snapMinutes * 60)))
        }
        return range
    }
}
