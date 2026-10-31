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

    init(rules: [String]) {
        custom = rules.joined(separator: "\n")
        if rules.isEmpty { frequency = "NONE" }
        else if rules.count == 1, let rule = rules.first, rule.hasPrefix("RRULE:") {
            let pairs = rule.dropFirst(6).split(separator: ";").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
            let fields = Dictionary(pairs.filter { $0.count == 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
            let supported = Set(["FREQ", "INTERVAL", "BYDAY", "COUNT"])
            if Set(fields.keys).isSubset(of: supported), let freq = fields["FREQ"], ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(freq),
               fields["BYDAY"] == nil || freq == "WEEKLY" && (fields["BYDAY"]?.split(separator: ",").allSatisfy { Self.dayCodes.contains(String($0)) } == true) {
                frequency = freq
                interval = max(1, Int(fields["INTERVAL"] ?? "1") ?? 1)
                weekdays = Set((fields["BYDAY"] ?? "").split(separator: ",").map(String.init))
                if let value = fields["COUNT"], let number = Int(value) { count = max(1, number); endMode = "count" }
            } else { frequency = "CUSTOM" }
        } else { frequency = "CUSTOM" }
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
}
