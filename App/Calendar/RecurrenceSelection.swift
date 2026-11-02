import Foundation

/// The recurrence editor's choices, read from and written back to RRULE lines.
/// Rules the editor can't show load as `CUSTOM` and keep their text.
struct RecurrenceSelection: Equatable {
    /// RRULE weekday codes, Monday first.
    static let dayCodes = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

    var frequency = "NONE"
    var interval = 1
    var weekdays = Set<String>()
    var endMode = "never"
    var count = 10
    var until = Date.now
    var custom = ""
    private var originalUntil: String?
    private var originalUntilDate: Date?
    private var originalAllDay = false
    private var originalTimeZoneID = ""

    init(rules: [String], allDay: Bool = false, timeZone: TimeZone = .autoupdatingCurrent) {
        custom = rules.joined(separator: "\n")
        guard !rules.isEmpty else { return }
        frequency = "CUSTOM"
        guard rules.count == 1, let rule = rules.first, rule.hasPrefix("RRULE:") else { return }
        let pairs = rule.dropFirst(6).split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) }
        guard pairs.allSatisfy({ $0.count == 2 && !$0[1].isEmpty }),
              Set(pairs.map { $0[0] }).count == pairs.count else { return }
        let fields = Dictionary(uniqueKeysWithValues: pairs.map { ($0[0], $0[1]) })
        let supported = Set(["FREQ", "INTERVAL", "BYDAY", "COUNT", "UNTIL"])
        guard Set(fields.keys).isSubset(of: supported), let freq = fields["FREQ"],
              ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(freq),
              let interval = Int(fields["INTERVAL"] ?? "1"), (1...999).contains(interval),
              fields["COUNT"] == nil || fields["UNTIL"] == nil else { return }
        let days = (fields["BYDAY"] ?? "").split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields["BYDAY"] == nil || (freq == "WEEKLY" && days.allSatisfy(Self.dayCodes.contains)) else { return }
        if let value = fields["COUNT"] {
            guard let count = Int(value), (1...9999).contains(count) else { return }
            self.count = count
            endMode = "count"
        }
        if let value = fields["UNTIL"] {
            guard let date = Self.parseUntil(value, allDay: allDay, timeZone: timeZone) else { return }
            until = date
            endMode = "until"
            originalUntil = value
            originalUntilDate = date
            originalAllDay = allDay
            originalTimeZoneID = timeZone.identifier
        }
        frequency = freq
        self.interval = interval
        weekdays = fields["BYDAY"] == nil ? [] : Set(days)
    }

    func rules(allDay: Bool, timeZone: TimeZone) -> [String] {
        if frequency == "NONE" { return [] }
        if frequency == "CUSTOM" {
            return custom.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var fields = ["FREQ=\(frequency)"]
        if interval > 1 { fields.append("INTERVAL=\(interval)") }
        if frequency == "WEEKLY", !weekdays.isEmpty { fields.append("BYDAY=" + Self.dayCodes.filter(weekdays.contains).joined(separator: ",")) }
        if endMode == "count" { fields.append("COUNT=\(count)") }
        if endMode == "until" {
            if let originalUntil, until == originalUntilDate, allDay == originalAllDay,
               timeZone.identifier == originalTimeZoneID {
                fields.append("UNTIL=" + originalUntil)
                return ["RRULE:" + fields.joined(separator: ";")]
            }
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            var eventCalendar = Calendar(identifier: .gregorian); eventCalendar.timeZone = timeZone
            if allDay {
                formatter.timeZone = timeZone; formatter.dateFormat = "yyyyMMdd"
                fields.append("UNTIL=" + formatter.string(from: until))
            } else {
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
                let nextDay = eventCalendar.date(byAdding: .day, value: 1, to: eventCalendar.startOfDay(for: until)) ?? until
                fields.append("UNTIL=" + formatter.string(from: nextDay.addingTimeInterval(-1)))
            }
        }
        return ["RRULE:" + fields.joined(separator: ";")]
    }

    private static func parseUntil(_ value: String, allDay: Bool, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        formatter.timeZone = allDay ? timeZone : TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = allDay ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss'Z'"
        guard value.count == (allDay ? 8 : 16), let date = formatter.date(from: value),
              formatter.string(from: date) == value else { return nil }
        return date
    }
}
