import Foundation
import MailStore

/// The schedule in the shape the profile editor shows: a mode, and hours that
/// date pickers can bind to.
extension ProfileNotificationSchedule {
    enum Mode: String, CaseIterable { case unrestricted, off, everyDay, weekdays, custom }

    /// Choosing a different mode starts it with 9 to 5 hours.
    var mode: Mode {
        get {
            switch self {
            case .unrestricted: .unrestricted
            case .off: .off
            case .everyDay: .everyDay
            case .weekdays: .weekdays
            case .custom: .custom
            }
        }
        set {
            guard newValue != mode else { return }
            let hours = [DailyTimeRange(startMinute: 9 * 60, endMinute: 17 * 60)]
            self = switch newValue {
            case .unrestricted: .unrestricted
            case .off: .off
            case .everyDay: .everyDay(hours)
            case .weekdays: .weekdays(hours)
            case .custom: .custom(Dictionary(uniqueKeysWithValues: ISOWeekday.allCases.map { ($0, hours) }))
            }
        }
    }

    /// The hours for `day` in a custom schedule, or for every day the schedule
    /// covers when `day` is nil.
    func ranges(_ day: ISOWeekday?) -> [DailyTimeRange] {
        switch self {
        case .everyDay(let values), .weekdays(let values): values
        case .custom(let days): day.flatMap { days[$0] } ?? []
        default: []
        }
    }

    mutating func setRanges(_ values: [DailyTimeRange], day: ISOWeekday?) {
        switch self {
        case .everyDay: self = .everyDay(values)
        case .weekdays: self = .weekdays(values)
        case .custom(var days): if let day { days[day] = values }; self = .custom(days)
        default: break
        }
    }

    /// One range of hours. A picker can outlive its row for a render, so reading
    /// past the end gives 9 to 5 and writing past it does nothing.
    subscript(day: ISOWeekday?, range index: Int) -> DailyTimeRange {
        get {
            let values = ranges(day)
            return values.indices.contains(index) ? values[index] : DailyTimeRange(startMinute: 9 * 60, endMinute: 17 * 60)
        }
        set {
            var values = ranges(day)
            guard values.indices.contains(index) else { return }
            values[index] = newValue
            setRanges(values, day: day)
        }
    }
}

extension DailyTimeRange {
    /// The start as a time on a fixed day, for an hour-and-minute picker.
    var startTime: Date {
        get { Self.time(atMinute: startMinute) }
        set { startMinute = Self.minute(of: newValue) }
    }

    /// The end as a time on a fixed day. Midnight ends the day.
    var endTime: Date {
        get { Self.time(atMinute: endMinute) }
        set {
            let minute = Self.minute(of: newValue)
            endMinute = minute == 0 ? 1440 : minute
        }
    }

    private static func time(atMinute minute: Int) -> Date {
        Calendar.autoupdatingCurrent.date(from: DateComponents(year: 2001, month: 1, day: 15,
            hour: (minute / 60) % 24, minute: minute % 60)) ?? .now
    }

    private static func minute(of date: Date) -> Int {
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
