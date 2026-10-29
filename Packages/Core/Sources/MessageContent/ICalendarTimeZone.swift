import Foundation

/// A date with no time, as in an all-day event.
public struct CalendarDay: Codable, Sendable, Hashable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public func adding(days: Int) -> CalendarDay {
        CalendarDay(dayNumber: dayNumber + days)
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar, after
    /// Howard Hinnant's `days_from_civil`.
    var dayNumber: Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    init(dayNumber: Int) {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        self.init(
            year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0),
            month: month,
            day: dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        )
    }

    /// 1 for Sunday through 7 for Saturday, as `Calendar` numbers them.
    var weekday: Int {
        // 1970-01-01 was a Thursday.
        (dayNumber % 7 + 11) % 7 + 1
    }

    var isValid: Bool {
        (1...12).contains(month) && (1...Self.length(ofMonth: month, in: year)).contains(day)
    }

    static func length(ofMonth month: Int, in year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// `yyyyMMdd`.
    var basicFormat: String {
        digits(year, 4) + digits(month, 2) + digits(day, 2)
    }
}

/// A wall-clock date and time with no zone.
public struct LocalDateTime: Codable, Sendable, Hashable, Comparable {
    public var day: CalendarDay
    public var hour: Int
    public var minute: Int
    public var second: Int

    public init(day: CalendarDay, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool {
        (lhs.day, lhs.hour, lhs.minute, lhs.second) < (rhs.day, rhs.hour, rhs.minute, rhs.second)
    }

    /// Seconds since 1970 if this wall-clock time were UTC, which makes an
    /// offset plain subtraction.
    var epochSeconds: Int {
        day.dayNumber * 86_400 + hour * 3600 + minute * 60 + second
    }

    init(epochSeconds: Int) {
        var days = epochSeconds / 86_400
        var remainder = epochSeconds % 86_400
        if remainder < 0 {
            remainder += 86_400
            days -= 1
        }
        self.init(day: CalendarDay(dayNumber: days), hour: remainder / 3600, minute: remainder % 3600 / 60, second: remainder % 60)
    }

    /// The UTC wall-clock time of `date`, to the second.
    init(utc date: Date) {
        self.init(epochSeconds: Int(date.timeIntervalSince1970.rounded(.down)))
    }

    var utcDate: Date { Date(timeIntervalSince1970: TimeInterval(epochSeconds)) }

    /// `yyyyMMdd'T'HHmmss`.
    var basicFormat: String {
        day.basicFormat + "T" + digits(hour, 2) + digits(minute, 2) + digits(second, 2)
    }
}

/// When an event starts or ends.
public enum EventTime: Codable, Sendable, Equatable {
    case allDay(CalendarDay)
    case utc(Date)
    /// A time with a TZID that matched an IANA zone or a VTIMEZONE in the
    /// same object. `utcOffset` is in seconds, at that moment.
    case zoned(Date, zone: String, utcOffset: Int)
    /// The same wall-clock time in every zone.
    case floating(LocalDateTime)
    /// A TZID that matched neither, shown as written with no conversion.
    case unresolved(LocalDateTime, zone: String)

    /// The moment, for times that name one.
    public var date: Date? {
        switch self {
        case .utc(let date), .zoned(let date, _, _): date
        case .allDay, .floating, .unresolved: nil
        }
    }
}

/// A DATE or DATE-TIME value before its zone is applied.
struct ICalendarTime: Equatable {
    enum Zone: Equatable {
        case date
        case utc
        case floating
        case named(String)
    }

    var local: LocalDateTime
    var zone: Zone

    init(local: LocalDateTime, zone: Zone) {
        self.local = local
        self.zone = zone
    }

    /// `yyyyMMdd`, `yyyyMMdd'T'HHmmss` or the same with `Z`. A TZID applies to
    /// the second form only.
    init?(_ property: ICalendarProperty) {
        let value = Array(property.value.trimmingCharacters(in: .whitespaces).uppercased().utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= value.count else { return nil }
            var number = 0
            for byte in value[range] {
                guard (0x30...0x39).contains(byte) else { return nil }
                number = number * 10 + Int(byte - 0x30)
            }
            return number
        }
        guard let year = number(0..<4), let month = number(4..<6), let dayOfMonth = number(6..<8) else { return nil }
        let day = CalendarDay(year: year, month: month, day: dayOfMonth)
        guard day.isValid else { return nil }
        if value.count == 8 {
            self.init(local: LocalDateTime(day: day), zone: .date)
            return
        }
        guard value.count == 15 || value.count == 16, value[8] == UInt8(ascii: "T"),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
              hour < 24, minute < 60, second <= 60 else { return nil }
        // A leap second reads as the second before it.
        let local = LocalDateTime(day: day, hour: hour, minute: minute, second: min(second, 59))
        if value.count == 16 {
            guard value[15] == UInt8(ascii: "Z") else { return nil }
            self.init(local: local, zone: .utc)
        } else if let tzid = property.parameter("TZID")?.trimmingCharacters(in: .whitespaces), !tzid.isEmpty {
            self.init(local: local, zone: .named(tzid))
        } else {
            self.init(local: local, zone: .floating)
        }
    }

    /// Wall-clock arithmetic, so a day is a calendar day across a daylight
    /// saving change.
    func adding(_ duration: ICalendarDuration) -> ICalendarTime {
        if zone == .date {
            return ICalendarTime(local: LocalDateTime(day: local.day.adding(days: duration.days + duration.seconds / 86_400)), zone: .date)
        }
        return ICalendarTime(local: LocalDateTime(epochSeconds: local.epochSeconds + duration.days * 86_400 + duration.seconds), zone: zone)
    }
}

/// A DURATION value: `[+-]P` with weeks, or days and a time part.
struct ICalendarDuration: Equatable {
    var days: Int
    var seconds: Int

    init(days: Int = 0, seconds: Int = 0) {
        self.days = days
        self.seconds = seconds
    }

    init?(_ value: String) {
        var text = Substring(value.trimmingCharacters(in: .whitespaces).uppercased())
        let sign = text.first == "-" ? -1 : 1
        if text.first == "-" || text.first == "+" { text = text.dropFirst() }
        guard text.first == "P" else { return nil }
        var days = 0
        var seconds = 0
        var number: Int?
        var inTime = false
        var sawComponent = false
        for character in text.dropFirst() {
            if character.isASCII, let digit = character.wholeNumberValue {
                // Caps each number well inside Int on the way to seconds.
                guard (number ?? 0) < 100_000_000 else { return nil }
                number = (number ?? 0) * 10 + digit
                continue
            }
            if character == "T", number == nil, !inTime {
                inTime = true
                continue
            }
            guard let value = number else { return nil }
            switch (character, inTime) {
            case ("W", false): days += value * 7
            case ("D", false): days += value
            case ("H", true): seconds += value * 3600
            case ("M", true): seconds += value * 60
            case ("S", true): seconds += value
            default: return nil
            }
            number = nil
            sawComponent = true
        }
        guard sawComponent, number == nil else { return nil }
        self.init(days: sign * days, seconds: sign * seconds)
    }
}

/// Applies TZIDs: an IANA name first, then the object's VTIMEZONE, else the
/// time stays as written.
struct TimeZoneResolver {
    private let definitions: [ICalendarComponent]

    init(_ calendar: ICalendarComponent) {
        definitions = calendar.components(named: "VTIMEZONE")
    }

    func definition(for tzid: String) -> ICalendarComponent? {
        func name(_ component: ICalendarComponent) -> String? {
            component.property("TZID")?.value.trimmingCharacters(in: .whitespaces)
        }
        return definitions.first { name($0) == tzid }
            ?? definitions.first { name($0)?.caseInsensitiveCompare(tzid) == .orderedSame }
    }

    func resolve(_ time: ICalendarTime) -> EventTime {
        switch time.zone {
        case .date:
            return .allDay(time.local.day)
        case .utc:
            return .utc(time.local.utcDate)
        case .floating:
            return .floating(time.local)
        case .named(let tzid):
            if let zone = Self.ianaZone(tzid), let date = Self.date(of: time.local, in: zone) {
                return .zoned(date, zone: tzid, utcOffset: zone.secondsFromGMT(for: date))
            }
            if let definition = definition(for: tzid), let rules = VTimeZone(definition) {
                let offset = rules.offset(at: time.local)
                return .zoned(Date(timeIntervalSince1970: TimeInterval(time.local.epochSeconds - offset)), zone: tzid, utcOffset: offset)
            }
            return .unresolved(time.local, zone: tzid)
        }
    }

    /// A TZID may start with "/" to mark a globally unique name.
    static func ianaZone(_ tzid: String) -> TimeZone? {
        TimeZone(identifier: tzid.hasPrefix("/") ? String(tzid.dropFirst()) : tzid)
    }

    private static func date(of local: LocalDateTime, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(
            year: local.day.year, month: local.day.month, day: local.day.day,
            hour: local.hour, minute: local.minute, second: local.second
        )
        return calendar.date(from: components)
    }
}

/// The STANDARD and DAYLIGHT blocks of a VTIMEZONE.
struct VTimeZone {
    struct Observance {
        /// Local time at `offsetFrom`.
        var start: LocalDateTime
        var offsetFrom: Int
        var offsetTo: Int
        var rule: YearlyRule?
        var dates: [LocalDateTime]

        /// The block's latest onset at or before `local`. Onsets, like
        /// DTSTART, are wall-clock times on the offset in force before them.
        func latestOnset(atOrBefore local: LocalDateTime) -> LocalDateTime? {
            var latest = start <= local ? start : nil
            func consider(_ onset: LocalDateTime) {
                if onset <= local, latest.map({ onset > $0 }) ?? true { latest = onset }
            }
            dates.forEach(consider)
            guard let rule else { return latest }

            let until: LocalDateTime? = rule.until.map { until in
                switch until.zone {
                case .utc: LocalDateTime(epochSeconds: until.local.epochSeconds + offsetFrom)
                // A DATE limit includes that whole day.
                case .date: LocalDateTime(day: until.local.day, hour: 23, minute: 59, second: 59)
                case .floating, .named: until.local
                }
            }
            var lastYear = local.day.year
            if let until { lastYear = min(lastYear, until.day.year) }
            if let count = rule.count { lastYear = min(lastYear, start.day.year + count - 1) }
            guard lastYear >= start.day.year else { return latest }
            for year in max(start.day.year, lastYear - 1)...lastYear {
                for onset in rule.onsets(in: year, at: start) where onset >= start && until.map({ onset <= $0 }) ?? true {
                    consider(onset)
                }
            }
            return latest
        }
    }

    var observances: [Observance]

    init?(_ component: ICalendarComponent) {
        observances = component.components.compactMap { block -> Observance? in
            guard block.name == "STANDARD" || block.name == "DAYLIGHT",
                  let start = block.property("DTSTART").flatMap(ICalendarTime.init)?.local,
                  let offsetTo = block.property("TZOFFSETTO").flatMap({ Self.utcOffset($0.value) }) else { return nil }
            let dates = block.properties(named: "RDATE").flatMap { property in
                property.value.split(separator: ",").compactMap { ICalendarTime(ICalendarProperty("RDATE", value: String($0)))?.local }
            }
            return Observance(
                start: start,
                offsetFrom: block.property("TZOFFSETFROM").flatMap { Self.utcOffset($0.value) } ?? offsetTo,
                offsetTo: offsetTo,
                rule: block.property("RRULE").flatMap { YearlyRule($0.value) },
                dates: dates
            )
        }
        guard !observances.isEmpty else { return nil }
    }

    /// The UTC offset in seconds at wall-clock time `local`: the `offsetTo`
    /// of the block with the latest onset at or before it. Before every
    /// onset, the earliest block's `offsetFrom` applies.
    func offset(at local: LocalDateTime) -> Int {
        var best: (onset: LocalDateTime, offset: Int)?
        for observance in observances {
            guard let onset = observance.latestOnset(atOrBefore: local) else { continue }
            if best.map({ onset >= $0.onset }) ?? true { best = (onset, observance.offsetTo) }
        }
        if let best { return best.offset }
        return observances.min { $0.start < $1.start }?.offsetFrom ?? 0
    }

    /// `+HHMM` or `-HHMMSS`, in seconds.
    static func utcOffset(_ value: String) -> Int? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard text.count == 5 || text.count == 7, let sign = text.first, sign == "+" || sign == "-",
              text.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let digits = text.dropFirst().compactMap(\.wholeNumberValue)
        let hours = digits[0] * 10 + digits[1]
        let minutes = digits[2] * 10 + digits[3]
        let seconds = digits.count == 6 ? digits[4] * 10 + digits[5] : 0
        guard hours < 24, minutes < 60, seconds < 60 else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60 + seconds)
    }
}

/// The part of an RRULE a time zone uses: yearly, by month, by weekday or day
/// of the month, with UNTIL or COUNT.
struct YearlyRule {
    struct Weekday {
        /// 2 for the second, -1 for the last, 0 for any.
        var ordinal: Int
        /// 1 for Sunday through 7 for Saturday.
        var weekday: Int
    }

    var months: [Int] = []
    var weekdays: [Weekday] = []
    var monthDays: [Int] = []
    var until: ICalendarTime?
    var count: Int?

    private static let weekdayNames = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    init?(_ value: String) {
        var parts: [String: String] = [:]
        for part in value.uppercased().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { parts[String(pair[0])] = String(pair[1]) }
        }
        guard parts["FREQ"] == "YEARLY" else { return nil }
        let list = { (key: String) in parts[key]?.split(separator: ",").map(String.init) ?? [] }
        months = list("BYMONTH").compactMap(Int.init).filter { (1...12).contains($0) }
        monthDays = list("BYMONTHDAY").compactMap(Int.init).filter { (1...31).contains(abs($0)) }
        weekdays = list("BYDAY").compactMap { item in
            guard item.count >= 2, let index = Self.weekdayNames.firstIndex(of: String(item.suffix(2))) else { return nil }
            let prefix = item.dropLast(2)
            guard let ordinal = prefix.isEmpty ? 0 : Int(prefix), abs(ordinal) <= 5 else { return nil }
            return Weekday(ordinal: ordinal, weekday: index + 1)
        }
        until = parts["UNTIL"].flatMap { ICalendarTime(ICalendarProperty("UNTIL", value: $0)) }
        count = parts["COUNT"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Onsets in `year`, at the time of day of `start`.
    func onsets(in year: Int, at start: LocalDateTime) -> [LocalDateTime] {
        (months.isEmpty ? [start.day.month] : months).compactMap { month in
            day(in: month, of: year, defaultDay: start.day.day).map {
                LocalDateTime(day: CalendarDay(year: year, month: month, day: $0), hour: start.hour, minute: start.minute, second: start.second)
            }
        }
    }

    private func day(in month: Int, of year: Int, defaultDay: Int) -> Int? {
        let length = CalendarDay.length(ofMonth: month, in: year)
        let allowedDays = monthDays.map { $0 > 0 ? $0 : length + 1 + $0 }.filter { (1...length).contains($0) }.sorted()
        // A time zone rule names one weekday.
        if let weekday = weekdays.first {
            let firstWeekday = CalendarDay(year: year, month: month, day: 1).weekday
            let matches = Array(stride(from: 1 + (weekday.weekday - firstWeekday + 7) % 7, through: length, by: 7))
            if weekday.ordinal > 0 { return weekday.ordinal <= matches.count ? matches[weekday.ordinal - 1] : nil }
            if weekday.ordinal < 0 { return -weekday.ordinal <= matches.count ? matches[matches.count + weekday.ordinal] : nil }
            // "SU" with BYMONTHDAY=8,…,14 is an older way to write "2SU".
            return matches.first { allowedDays.isEmpty || allowedDays.contains($0) }
        }
        if let first = allowedDays.first { return first }
        return min(defaultDay, length)
    }
}

private func digits(_ value: Int, _ width: Int) -> String {
    let text = String(abs(value))
    return (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - text.count)) + text
}
