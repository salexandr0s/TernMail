import Foundation

/// Produces explicit historical observances and the stable annual rules supplied
/// by the system time-zone database. Irregular future schedules are rejected.
enum ICalendarZoneExport {
    private struct Transition {
        let instant: Date
        let local: LocalDateTime
        let from: Int
        let to: Int
        let daylight: Bool
        let rule: String
    }

    static func component(zone: TimeZone, startingAt start: Date, now: Date = Date()) throws -> ICalendarComponent {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? zone
        let startYear = calendar.component(.year, from: start) - 1
        let horizonYear = max(calendar.component(.year, from: now), startYear + 1) + 4
        guard horizonYear - startYear < 250,
              let baseline = calendar.date(from: DateComponents(year: startYear, month: 1, day: 1)),
              let horizon = calendar.date(from: DateComponents(year: horizonYear, month: 1, day: 1)) else {
            throw CalendarInterchangeError.unsupportedTimeZoneExport(zone.identifier)
        }
        let initialOffset = zone.secondsFromGMT(for: baseline)
        var components = [observance(local: LocalDateTime(epochSeconds: Int(baseline.timeIntervalSince1970) + initialOffset),
                                     from: initialOffset, to: initialOffset, daylight: zone.isDaylightSavingTime(for: baseline))]
        var transitions: [Transition] = []
        var cursor = baseline
        while let instant = zone.nextDaylightSavingTimeTransition(after: cursor), instant < horizon {
            guard instant > cursor, transitions.count < 512 else {
                throw CalendarInterchangeError.unsupportedTimeZoneExport(zone.identifier)
            }
            let from = zone.secondsFromGMT(for: instant.addingTimeInterval(-1))
            let to = zone.secondsFromGMT(for: instant)
            let local = LocalDateTime(epochSeconds: Int(instant.timeIntervalSince1970) + from)
            let lastWeek = local.day.day + 7 > CalendarDay.length(ofMonth: local.day.month, in: local.day.year)
            let ordinal = lastWeek ? -1 : (local.day.day - 1) / 7 + 1
            let weekday = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][local.day.weekday - 1]
            let rule = "FREQ=YEARLY;BYMONTH=\(local.day.month);BYDAY=\(ordinal)\(weekday)"
            transitions.append(Transition(instant: instant, local: local, from: from, to: to,
                                          daylight: zone.isDaylightSavingTime(for: instant), rule: rule))
            cursor = instant.addingTimeInterval(1)
        }
        var recurringIndices = Set<Int>()
        if zone.nextDaylightSavingTimeTransition(after: horizon) != nil {
            for daylight in [false, true] {
                let indices = transitions.indices.filter { transitions[$0].daylight == daylight }
                guard let last = indices.last else { continue }
                let recent = indices.suffix(3).map { transitions[$0] }
                guard recent.count == 3,
                      Set(recent.map { $0.local.day.year }).count == 3,
                      recent.allSatisfy({ $0.rule == transitions[last].rule && $0.from == transitions[last].from
                          && $0.to == transitions[last].to && $0.local.hour == transitions[last].local.hour
                          && $0.local.minute == transitions[last].local.minute }) else {
                    throw CalendarInterchangeError.unsupportedTimeZoneExport(zone.identifier)
                }
                recurringIndices.insert(last)
            }
        }
        for (index, transition) in transitions.enumerated() {
            var value = observance(local: transition.local, from: transition.from, to: transition.to, daylight: transition.daylight)
            if recurringIndices.contains(index) { value.properties.append(ICalendarProperty("RRULE", value: transition.rule)) }
            components.append(value)
        }
        return ICalendarComponent(name: "VTIMEZONE", properties: [
            ICalendarProperty("TZID", value: zone.identifier),
            ICalendarProperty("X-LIC-LOCATION", value: ICalendar.escape(zone.identifier)),
        ], components: components)
    }

    private static func observance(local: LocalDateTime, from: Int, to: Int, daylight: Bool) -> ICalendarComponent {
        ICalendarComponent(name: daylight ? "DAYLIGHT" : "STANDARD", properties: [
            ICalendarProperty("DTSTART", value: local.basicFormat),
            ICalendarProperty("TZOFFSETFROM", value: offset(from)),
            ICalendarProperty("TZOFFSETTO", value: offset(to)),
        ])
    }

    private static func offset(_ seconds: Int) -> String {
        let absolute = abs(seconds)
        let basic = String(format: "%@%02d%02d", seconds < 0 ? "-" : "+", absolute / 3600, absolute % 3600 / 60)
        return absolute % 60 == 0 ? basic : basic + String(format: "%02d", absolute % 60)
    }
}
