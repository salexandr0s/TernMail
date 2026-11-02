import Foundation
import SwiftUI

/// Immutable layout inputs, prepared once per range/data revision rather than
/// during selection, hover, scrolling or a switch back to Calendar.
struct CalendarPresentationSnapshot: Sendable {
    let id = UUID()
    struct Day: Sendable {
        let events: [CalendarDisplayEvent]
        let allDay: [CalendarDisplayEvent]
        let timed: [CalendarDisplayEvent]
        let placements: [CalendarTimelinePlacement]
    }

    let interval: DateInterval
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    let days: [Date]
    let timeAxis: CalendarTimeAxis?
    private let buckets: [Date: Day]

    init(events: [CalendarDisplayEvent], interval: DateInterval, calendar: Calendar, buildsTimeAxis: Bool) {
        self.interval = interval
        self.calendar = calendar
        self.events = events
        days = CalendarLayout.days(in: interval, calendar: calendar)
        let axis = buildsTimeAxis ? CalendarTimeAxis(days: days, calendar: calendar) : nil
        timeAxis = axis
        var byDay: [Date: [CalendarDisplayEvent]] = [:]
        // Sort once, then distribute in that order. The end of an all-day event
        // is exclusive, including across 23/25-hour daylight-saving days.
        let ordered = events.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            return $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
        for event in ordered {
            let end = min(interval.end, max(event.end, event.start.addingTimeInterval(1)))
            var day = calendar.startOfDay(for: max(interval.start, event.start))
            while day < end, day < interval.end {
                byDay[day, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        var prepared = byDay.mapValues { entries in
            let allDay = entries.filter(\.isAllDay)
            let timed = entries.filter { !$0.isAllDay }
            return Day(events: entries, allDay: allDay, timed: timed, placements: [])
        }
        if let axis {
            for day in days {
                guard let bucket = prepared[day] else { continue }
                prepared[day] = Day(events: bucket.events, allDay: bucket.allDay, timed: bucket.timed,
                    placements: CalendarTimelinePlacement.layout(bucket.timed, day: day, axis: axis))
            }
        }
        buckets = prepared
    }

    func day(_ day: Date) -> Day? { buckets[calendar.startOfDay(for: day)] }

    func matches(_ calendar: Calendar) -> Bool {
        self.calendar.identifier == calendar.identifier && self.calendar.timeZone == calendar.timeZone
            && self.calendar.firstWeekday == calendar.firstWeekday
    }
}

private struct CalendarPresentationKey: EnvironmentKey {
    static let defaultValue: CalendarPresentationSnapshot? = nil
}

extension EnvironmentValues {
    var calendarPresentation: CalendarPresentationSnapshot? {
        get { self[CalendarPresentationKey.self] }
        set { self[CalendarPresentationKey.self] = newValue }
    }
}
