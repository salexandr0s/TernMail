import Foundation

/// The wake times the Snooze menu offers, worked out in the user's calendar so
/// its time zone, first weekday and weekend apply.
struct SnoozeSchedule {
    enum Preset: Equatable, CaseIterable {
        case laterToday, tomorrow, thisWeekend, nextWeek
    }

    struct Option: Equatable {
        let preset: Preset
        let wakeAt: Date
    }

    static let eveningHour = 18
    static let morningHour = 8
    /// Later Today is offered until this hour.
    static let laterTodayCutoffHour = 17

    var calendar: Calendar = .autoupdatingCurrent

    /// The presets that apply at `now`, in menu order. A preset that lands on
    /// the same moment as an earlier one is left out, so Friday shows Tomorrow
    /// but not This Weekend.
    func options(now: Date) -> [Option] {
        var options: [Option] = []
        for preset in Preset.allCases {
            guard let wakeAt = wakeTime(for: preset, now: now),
                  wakeAt > now,
                  !options.contains(where: { $0.wakeAt == wakeAt })
            else { continue }
            options.append(Option(preset: preset, wakeAt: wakeAt))
        }
        return options
    }

    func wakeTime(for preset: Preset, now: Date) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch preset {
        case .laterToday:
            guard let cutoff = at(Self.laterTodayCutoffHour, on: today), now < cutoff else { return nil }
            return at(Self.eveningHour, on: today)
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: today).flatMap { at(Self.morningHour, on: $0) }
        case .thisWeekend:
            guard !calendar.isDateInWeekend(now),
                  let weekend = calendar.nextWeekend(startingAfter: now)
            else { return nil }
            return at(Self.morningHour, on: weekend.start)
        case .nextWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return at(Self.morningHour, on: week.end)
        }
    }

    private func at(_ hour: Int, on day: Date) -> Date? {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }
}
