import Foundation
import GmailAPI

public struct CalendarWorkingHours: Codable, Sendable, Equatable {
    /// Calendar weekday numbers: Sunday is 1, Monday is 2.
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int
    public var durationMinutes: Int
    public var stepMinutes: Int
    public var timeZoneIdentifier: String

    public init(timeZoneIdentifier: String = TimeZone.current.identifier, weekdays: Set<Int> = [2, 3, 4, 5, 6],
                startMinute: Int = 540, endMinute: Int = 1020, durationMinutes: Int = 30, stepMinutes: Int = 15) {
        self.timeZoneIdentifier = timeZoneIdentifier; self.weekdays = weekdays
        self.startMinute = startMinute; self.endMinute = endMinute
        self.durationMinutes = durationMinutes; self.stepMinutes = stepMinutes
    }

    public var isValid: Bool {
        TimeZone(identifier: timeZoneIdentifier) != nil && !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) }
            && (0..<1440).contains(startMinute) && (1...1440).contains(endMinute) && startMinute < endMinute
            && (1...1440).contains(durationMinutes) && (1...1440).contains(stepMinutes)
    }
}

public struct CalendarAvailableSlot: Codable, Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    public var id: String { "\(start.timeIntervalSince1970)/\(end.timeIntervalSince1970)" }
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

public struct CalendarAvailabilityResult: Sendable, Equatable {
    public var calendarIDs: [String]
    public var timeZone: String
    public var checkedAt: Date
    public var busy: [CalendarBusyInterval]
    public var slots: [CalendarAvailableSlot]
    public var failures: [String: String]
    public var isComplete: Bool { !calendarIDs.isEmpty && failures.isEmpty }

    public init(calendarIDs: [String], timeZone: String, checkedAt: Date = .now,
                busy: [CalendarBusyInterval], slots: [CalendarAvailableSlot], failures: [String: String] = [:]) {
        self.calendarIDs = calendarIDs; self.timeZone = timeZone; self.checkedAt = checkedAt
        self.busy = busy; self.slots = slots; self.failures = failures
    }
}

public enum CalendarAvailability {
    /// Invalid inputs fail closed. The caller must obtain a complete set of busy
    /// intervals first; missing calendars must never be passed as empty calendars.
    public static func findSlots(start: Date, end: Date, busy: [CalendarBusyInterval],
                                 hours: CalendarWorkingHours, limit: Int = 20) -> [CalendarAvailableSlot] {
        guard hours.isValid, end > start, end.timeIntervalSince(start) <= 366 * 86400,
              let timeZone = TimeZone(identifier: hours.timeZoneIdentifier), limit > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parsed = busy.compactMap { interval -> DateInterval? in
            guard let start = interval.startDate, let end = interval.endDate, end >= start else { return nil }
            return DateInterval(start: start, end: end)
        }
        guard parsed.count == busy.count else { return [] }
        let blocks = merged(parsed)
        var day = calendar.startOfDay(for: start)
        var slots: [CalendarAvailableSlot] = []
        while day < end, slots.count < min(limit, 200) {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            defer { day = nextDay }
            guard hours.weekdays.contains(calendar.component(.weekday, from: day)),
                  let workingStart = time(on: day, minute: hours.startMinute, calendar: calendar),
                  let workingEnd = time(on: day, minute: hours.endMinute, calendar: calendar) else { continue }
            var cursor = workingStart
            while cursor < workingEnd, cursor < end, slots.count < min(limit, 200) {
                let candidateEnd = cursor.addingTimeInterval(Double(hours.durationMinutes) * 60)
                if cursor >= start, candidateEnd <= workingEnd, candidateEnd <= end,
                   !blocks.contains(where: { $0.start < candidateEnd && $0.end > cursor }) {
                    slots.append(CalendarAvailableSlot(start: cursor, end: candidateEnd))
                }
                cursor = cursor.addingTimeInterval(Double(hours.stepMinutes) * 60)
            }
        }
        return slots
    }

    private static func time(on day: Date, minute: Int, calendar: Calendar) -> Date? {
        if minute == 1440 { return calendar.date(byAdding: .day, value: 1, to: day) }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }

    private static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end >= interval.start {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { result.append(interval) }
        }
        return result
    }
}
