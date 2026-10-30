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

    static func snappedMinute(at y: CGFloat, hourHeight: CGFloat, allowEndOfDay: Bool = false) -> Int {
        guard y.isFinite, hourHeight > 0 else { return 0 }
        let minute = min(1440, max(0, y / hourHeight * 60))
        let snapped = Int((minute / CGFloat(snapMinutes)).rounded()) * snapMinutes
        return min(allowEndOfDay ? 1440 : 1440 - snapMinutes, max(0, snapped))
    }

    static func date(at minute: Int, on day: Date, calendar: Calendar) -> Date {
        if minute >= 1440 {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day
        }
        return CalendarLayout.date(at: max(0, minute), on: day, calendar: calendar)
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
