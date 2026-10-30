import Foundation
import GmailAPI

/// Splits the recurrence set, not Google's expanded (already excluded) instances.
/// COUNT applies to RRULE candidates before EXDATE removes any of them (RFC 5545).
struct CalendarRecurrencePartition {
    var before: [String]
    var following: [String]
    var futureExclusionCount: Int

    init(lines: [String], start: CalendarDateTime, split: CalendarDateTime,
         timeZone fallback: TimeZone, preservingSchedule: Bool = true) throws {
        let zone = start.timeZone.flatMap(TimeZone.init(identifier:)) ?? fallback
        guard let beginning = start.resolvedDate(fallbackTimeZone: zone),
              let boundary = split.resolvedDate(fallbackTimeZone: zone), boundary > beginning else {
            throw CalendarEngineError.unsupportedRecurrence
        }
        let parsed = try ParsedRecurrence(lines, zone: zone, allDay: start.isAllDay)
        let counter: RuleCount?
        if parsed.rule.parts["COUNT"] != nil {
            counter = try parsed.rule.count(before: boundary, beginning: beginning, zone: zone, allDay: start.isAllDay)
        } else { counter = nil }
        let endedByUntil = try parsed.rule.parts["UNTIL"].map { try ParsedRecurrence.date($0, zone: zone, allDay: start.isAllDay) < boundary } ?? false
        let until = try Self.until(before: boundary, allDay: start.isAllDay, zone: zone)
        var originalRule = parsed.rule.line
        // Do not extend a COUNT/UNTIL series when the selected occurrence came
        // from a later RDATE after its RRULE had already ended.
        if counter?.remaining != 0 {
            if let existing = parsed.rule.parts["UNTIL"],
               try ParsedRecurrence.date(existing, zone: zone, allDay: start.isAllDay) < boundary {
                originalRule = parsed.rule.line
            } else {
                originalRule = parsed.rule.replacing("COUNT", with: nil)
                originalRule = Rule.replacing(originalRule, "UNTIL", with: until)
            }
        }
        before = [originalRule]
        following = counter?.remaining == 0 || endedByUntil ? [] : [counter.map { parsed.rule.replacing("COUNT", with: String($0.remaining)) } ?? parsed.rule.line]
        futureExclusionCount = 0
        var splitIsAddedDate = false
        for line in parsed.dates {
            let earlier = line.values.filter { $0.date < boundary }
            let later = line.values.filter { $0.date >= boundary }
            if !earlier.isEmpty { before.append(line.prefix + earlier.map(\.raw).joined(separator: ",")) }
            if !later.isEmpty { following.append(line.prefix + later.map(\.raw).joined(separator: ",")) }
            if line.isExclusion { futureExclusionCount += later.count }
            else if line.values.contains(where: { $0.date == boundary }) { splitIsAddedDate = true }
        }
        // An off-rule RDATE cannot safely become the anchor of an unchanged
        // interval rule. If its rule has ended, the remaining explicit dates work.
        if preservingSchedule, counter?.remaining != 0, !endedByUntil, splitIsAddedDate {
            let membership = try counter ?? parsed.rule.count(before: boundary, beginning: beginning, zone: zone, allDay: start.isAllDay)
            guard membership.containsBoundary else { throw CalendarEngineError.unsupportedRecurrence }
        }
    }

    static func reviewedFollowing(_ lines: [String], split: CalendarDateTime, timeZone: TimeZone) throws -> [String] {
        guard let boundary = split.resolvedDate(fallbackTimeZone: timeZone) else { throw CalendarEngineError.invalidEvent }
        let parsed = try ParsedRecurrence(lines, zone: timeZone, allDay: split.isAllDay)
        return [parsed.rule.line] + parsed.dates.compactMap { line in
            let later = line.values.filter { $0.date >= boundary }
            return later.isEmpty ? nil : line.prefix + later.map(\.raw).joined(separator: ",")
        }
    }

    private static func until(before date: Date, allDay: Bool, zone: TimeZone) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if allDay {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { throw CalendarEngineError.invalidEvent }
            formatter.timeZone = zone; formatter.dateFormat = "yyyyMMdd"
            return formatter.string(from: previous)
        }
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date.addingTimeInterval(-1))
    }
}

private struct ParsedRecurrence {
    struct DateLine {
        var prefix: String
        var isExclusion: Bool
        var values: [(raw: String, date: Date)]
    }
    var rule: Rule
    var dates: [DateLine]

    init(_ lines: [String], zone: TimeZone, allDay: Bool) throws {
        var rules: [Rule] = [], dates: [DateLine] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), !line.contains("\n"), !line.contains("\r") else {
                throw CalendarEngineError.unsupportedRecurrence
            }
            let header = String(line[..<colon]), value = String(line[line.index(after: colon)...])
            let components = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard let name = components.first?.uppercased() else { throw CalendarEngineError.unsupportedRecurrence }
            if name == "RRULE", components.count == 1 { rules.append(try Rule(line)); continue }
            guard name == "EXDATE" || name == "RDATE" else { throw CalendarEngineError.unsupportedRecurrence }
            var dateZone = zone, declaredType: String?, sawZone = false
            for parameter in components.dropFirst() {
                let pieces = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { throw CalendarEngineError.unsupportedRecurrence }
                let key = pieces[0].uppercased(), raw = String(pieces[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if key == "TZID", !sawZone, let resolved = TimeZone(identifier: raw) { dateZone = resolved; sawZone = true }
                else if key == "VALUE", declaredType == nil { declaredType = raw.uppercased() }
                else { throw CalendarEngineError.unsupportedRecurrence }
            }
            guard declaredType == nil || declaredType == (allDay ? "DATE" : "DATE-TIME"), !allDay || !sawZone else {
                throw CalendarEngineError.unsupportedRecurrence
            }
            let values = try value.split(separator: ",", omittingEmptySubsequences: false).map { raw -> (raw: String, date: Date) in
                let raw = String(raw)
                guard !(sawZone && raw.hasSuffix("Z")) else { throw CalendarEngineError.unsupportedRecurrence }
                return (raw, try Self.date(raw, zone: dateZone, allDay: allDay))
            }
            dates.append(DateLine(prefix: String(line[...colon]), isExclusion: name == "EXDATE", values: values))
        }
        guard rules.count == 1, let rule = rules.first else { throw CalendarEngineError.unsupportedRecurrence }
        self.rule = rule; self.dates = dates
    }

    static func date(_ raw: String, zone: TimeZone, allDay: Bool) throws -> Date {
        let expected = allDay ? 8 : (raw.hasSuffix("Z") ? 16 : 15)
        guard raw.count == expected else { throw CalendarEngineError.unsupportedRecurrence }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = raw.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : zone
        formatter.dateFormat = allDay ? "yyyyMMdd" : (raw.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss")
        formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
            throw CalendarEngineError.unsupportedRecurrence
        }
        return date
    }
}

private struct RuleCount { var remaining: Int; var containsBoundary: Bool }

private struct Rule {
    var line: String
    var parts: [String: String]
    init(_ line: String) throws {
        var parts: [String: String] = [:]
        for item in line.dropFirst(6).split(separator: ";", omittingEmptySubsequences: false) {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[1].isEmpty, parts[pair[0].uppercased()] == nil else { throw CalendarEngineError.unsupportedRecurrence }
            parts[pair[0].uppercased()] = pair[1].uppercased()
        }
        guard parts["FREQ"] != nil, !(parts["COUNT"] != nil && parts["UNTIL"] != nil) else { throw CalendarEngineError.unsupportedRecurrence }
        self.line = line; self.parts = parts
    }
    func replacing(_ key: String, with value: String?) -> String { Self.replacing(line, key, with: value) }
    static func replacing(_ line: String, _ key: String, with value: String?) -> String {
        let kept = line.dropFirst(6).split(separator: ";").filter { !$0.uppercased().hasPrefix(key + "=") }.map(String.init)
        return "RRULE:" + (kept + (value.map { [key + "=" + $0] } ?? [])).joined(separator: ";")
    }

    /// Count nominal dates from one ordinary calendar rule. Bounded enumeration
    /// intentionally rejects sub-daily, week-number and year-day extensions.
    func count(before boundary: Date, beginning: Date, zone: TimeZone, allDay: Bool) throws -> RuleCount {
        let allowed: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYSETPOS", "WKST"]
        guard allowed.isSuperset(of: parts.keys), let frequency = parts["FREQ"],
              ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(frequency),
              let interval = Int(parts["INTERVAL"] ?? "1"), interval > 0, interval <= 10_000,
              let limit = Int(parts["COUNT"] ?? "100000"), limit > 0, limit <= 100_000 else { throw CalendarEngineError.unsupportedRecurrence }
        let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        guard let firstWeekday = weekdays[parts["WKST"] ?? "MO"] else { throw CalendarEngineError.unsupportedRecurrence }
        let months = try integers("BYMONTH", range: 1...12, nonzero: true)
        let monthDays = try integers("BYMONTHDAY", range: -31...31, nonzero: true)
        let positions = try integers("BYSETPOS", range: -366...366, nonzero: true)
        let days: [(ordinal: Int?, weekday: Int)] = try (parts["BYDAY"]?.split(separator: ",").map(String.init) ?? []).map { text in
            guard let weekday = weekdays[String(text.suffix(2))] else { throw CalendarEngineError.unsupportedRecurrence }
            let prefix = String(text.dropLast(2)), ordinal = prefix.isEmpty ? nil : Int(prefix)
            guard prefix.isEmpty || (ordinal != nil && ordinal != 0 && abs(ordinal ?? 0) <= 53),
                  ordinal == nil || frequency == "MONTHLY" || frequency == "YEARLY" else { throw CalendarEngineError.unsupportedRecurrence }
            return (ordinal, weekday)
        }
        guard frequency != "WEEKLY" || monthDays.isEmpty,
              positions.isEmpty || !months.isEmpty || !monthDays.isEmpty || !days.isEmpty else { throw CalendarEngineError.unsupportedRecurrence }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; calendar.firstWeekday = firstWeekday
        let initial = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: beginning)
        let component: Calendar.Component = frequency == "YEARLY" ? .year : frequency == "MONTHLY" ? .month : frequency == "WEEKLY" ? .weekOfYear : .day
        guard var period = calendar.dateInterval(of: component, for: beginning)?.start else { throw CalendarEngineError.unsupportedRecurrence }
        let until = try parts["UNTIL"].map { try ParsedRecurrence.date($0, zone: zone, allDay: allDay) }
        var total = 0, scanned = 0, firstSeen = false
        while period <= boundary, total < limit {
            guard let end = calendar.date(byAdding: component, value: 1, to: period) else { throw CalendarEngineError.unsupportedRecurrence }
            var day = period, candidates: [Date] = []
            while day < end {
                scanned += 1
                guard scanned <= 200_000 else { throw CalendarEngineError.unsupportedRecurrence }
                let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                let monthMatches = months.isEmpty || months.contains(c.month ?? 0)
                let monthLength = calendar.range(of: .day, in: .month, for: day)?.count ?? 0
                let monthDayMatches = monthDays.isEmpty || monthDays.contains { $0 > 0 ? $0 == c.day : monthLength + $0 + 1 == c.day }
                let weekdayMatches = days.isEmpty || days.contains { entry in
                    guard entry.weekday == c.weekday else { return false }
                    guard let ordinal = entry.ordinal else { return true }
                    let yearly = frequency == "YEARLY" && months.isEmpty
                    let position = yearly ? (calendar.ordinality(of: .day, in: .year, for: day) ?? 0) : (c.day ?? 0)
                    let length = yearly ? (calendar.range(of: .day, in: .year, for: day)?.count ?? 0) : monthLength
                    return ordinal > 0 ? (position - 1) / 7 + 1 == ordinal : (length - position) / 7 + 1 == -ordinal
                }
                let defaultMatches: Bool
                if frequency == "WEEKLY", days.isEmpty { defaultMatches = c.weekday == initial.weekday }
                else if ["MONTHLY", "YEARLY"].contains(frequency), monthDays.isEmpty, days.isEmpty {
                    defaultMatches = c.day == initial.day && (frequency != "YEARLY" || !months.isEmpty || c.month == initial.month)
                } else { defaultMatches = true }
                if monthMatches && monthDayMatches && weekdayMatches && defaultMatches {
                    var components = c; components.weekday = nil
                    components.hour = allDay ? 0 : initial.hour; components.minute = allDay ? 0 : initial.minute; components.second = allDay ? 0 : initial.second
                    if let candidate = calendar.date(from: components), calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate) == components {
                        candidates.append(candidate)
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { throw CalendarEngineError.unsupportedRecurrence }
                day = next
            }
            if !positions.isEmpty {
                candidates = Array(Set(positions.compactMap { position -> Date? in
                    let index = position > 0 ? position - 1 : candidates.count + position
                    return candidates.indices.contains(index) ? candidates[index] : nil
                })).sorted()
            }
            for candidate in candidates where candidate >= beginning {
                if !firstSeen { guard candidate == beginning else { throw CalendarEngineError.unsupportedRecurrence }; firstSeen = true }
                if let until, candidate > until { return RuleCount(remaining: limit - total, containsBoundary: false) }
                if candidate >= boundary { return RuleCount(remaining: limit - total, containsBoundary: candidate == boundary) }
                total += 1
                if total == limit { return RuleCount(remaining: 0, containsBoundary: false) }
            }
            guard let next = calendar.date(byAdding: component, value: interval, to: period), next > period else { throw CalendarEngineError.unsupportedRecurrence }
            period = next
        }
        return RuleCount(remaining: limit - total, containsBoundary: false)
    }

    private func integers(_ name: String, range: ClosedRange<Int>, nonzero: Bool) throws -> [Int] {
        guard let raw = parts[name] else { return [] }
        return try raw.split(separator: ",", omittingEmptySubsequences: false).map {
            guard let value = Int($0), range.contains(value), !nonzero || value != 0 else { throw CalendarEngineError.unsupportedRecurrence }
            return value
        }
    }
}
