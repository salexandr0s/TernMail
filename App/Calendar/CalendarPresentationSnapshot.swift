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
        let agendaOrder: [Int]?

        var agendaEvents: [CalendarDisplayEvent] {
            agendaOrder?.map { events[$0] } ?? events
        }
    }

    struct DayActivity: Equatable, Sendable {
        var count = 0
        var colors: [String] = []
        var description: String { count == 1 ? "1 event" : "\(count) events" }
    }

    let interval: DateInterval
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    let days: [Date]
    let timeAxis: CalendarTimeAxis?
    let dayActivities: [Date: DayActivity]
    private let buckets: [Date: Day]

    init(events: [CalendarDisplayEvent], interval: DateInterval, calendar: Calendar, buildsTimeAxis: Bool) {
        self.interval = interval
        self.calendar = calendar
        self.events = events
        days = CalendarLayout.days(in: interval, calendar: calendar)
        dayActivities = Self.makeDayActivities(events: events, days: days, calendar: calendar)
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
        let sourceOrder = Dictionary(events.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        var prepared = byDay.mapValues { entries in
            let allDay = entries.filter(\.isAllDay)
            let timed = entries.filter { !$0.isAllDay }
            // The sidebar keeps source order for simultaneous events. Store only
            // indices when that differs from the grid's deterministic ID order.
            let agendaOrder = entries.indices.sorted { lhs, rhs in
                let left = entries[lhs], right = entries[rhs]
                if left.isAllDay == right.isAllDay, left.start == right.start {
                    return sourceOrder[left.id, default: 0] < sourceOrder[right.id, default: 0]
                }
                return lhs < rhs
            }
            return Day(events: entries, allDay: allDay, timed: timed, placements: [],
                agendaOrder: agendaOrder.elementsEqual(entries.indices) ? nil : agendaOrder)
        }
        if let axis {
            for day in days {
                guard let bucket = prepared[day] else { continue }
                prepared[day] = Day(events: bucket.events, allDay: bucket.allDay, timed: bucket.timed,
                    placements: CalendarTimelinePlacement.layout(bucket.timed, day: day, axis: axis),
                    agendaOrder: bucket.agendaOrder)
            }
        }
        buckets = prepared
    }

    func day(_ day: Date) -> Day? { buckets[calendar.startOfDay(for: day)] }

    func agenda(on day: Date, calendar: Calendar) -> [CalendarDisplayEvent]? {
        guard covers([day], calendar: calendar) else { return nil }
        return self.day(day)?.agendaEvents ?? []
    }

    func covers(_ days: [Date], calendar: Calendar) -> Bool {
        guard matches(calendar), let first = days.min(), let last = days.max(),
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else { return false }
        return interval.start <= calendar.startOfDay(for: first) && interval.end >= end
    }

    func matches(_ calendar: Calendar) -> Bool {
        self.calendar.identifier == calendar.identifier && self.calendar.timeZone == calendar.timeZone
            && self.calendar.firstWeekday == calendar.firstWeekday
    }

    /// Marker colors retain source order, independently of the grid's event sorting.
    static func makeDayActivities(events: [CalendarDisplayEvent], days: [Date], calendar: Calendar) -> [Date: DayActivity] {
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [:] }
        var result: [Date: DayActivity] = [:]
        for event in events {
            let eventEnd = max(event.end, event.start.addingTimeInterval(1))
            guard event.start < end, eventEnd > first else { continue }
            var day = calendar.startOfDay(for: max(first, event.start))
            let lastMoment = min(end, eventEnd)
            while day < lastMoment {
                var activity = result[day, default: DayActivity()]
                activity.count += 1
                let color = event.colorHex.lowercased()
                if activity.colors.count < 3, !activity.colors.contains(color) { activity.colors.append(color) }
                result[day] = activity
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        return result
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
