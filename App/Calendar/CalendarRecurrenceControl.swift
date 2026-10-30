import SwiftUI

/// Preserves provider rules until the user chooses a replacement pattern.
struct CalendarRecurrenceControl: View {
    @Binding var rules: [String]
    var allDay = false
    var timeZone = TimeZone.autoupdatingCurrent
    @State private var frequency = "NONE"
    @State private var interval = 1
    @State private var weekdays = Set<String>()
    @State private var endMode = "never"
    @State private var count = 10
    @State private var until = Date.now
    @State private var custom = ""
    @State private var loaded = false
    private let dayCodes = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
    private let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Picker("Repeat", selection: publishing($frequency)) {
                Text("Never").tag("NONE")
                Text("Daily").tag("DAILY")
                Text("Weekly").tag("WEEKLY")
                Text("Monthly").tag("MONTHLY")
                Text("Yearly").tag("YEARLY")
                Text("Custom rule").tag("CUSTOM")
            }
            if frequency == "CUSTOM" {
                TextEditor(text: publishing($custom)).font(.system(.caption, design: .monospaced))
                    .frame(minHeight: Tokens.Space.s16 + Tokens.Space.s2)
                    .accessibilityLabel("Recurrence rules")
                Text("One RRULE, RDATE or EXDATE per line. Existing custom rules are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if frequency != "NONE" {
                Stepper("Every \(interval) \(unit)", value: publishing($interval), in: 1...999)
                if frequency == "WEEKLY" {
                    HStack(spacing: Tokens.Space.s1) {
                        ForEach(Array(dayCodes.enumerated()), id: \.element) { index, code in
                            Toggle(dayNames[index], isOn: Binding(
                                get: { weekdays.contains(code) },
                                set: { included in
                                    if included { weekdays.insert(code) } else { weekdays.remove(code) }
                                    publish()
                                }
                            ))
                            .toggleStyle(.button)
                            .accessibilityLabel(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][index])
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                Picker("Ends", selection: publishing($endMode)) {
                    Text("Never").tag("never"); Text("After occurrences").tag("count"); Text("On date").tag("until")
                }
                if endMode == "count" { Stepper("After \(count) events", value: publishing($count), in: 1...9999) }
                if endMode == "until" { DatePicker("Last date", selection: publishing($until), displayedComponents: .date) }
            }
        }
        .onAppear(perform: load)
        .onChange(of: allDay) { _, _ in if endMode == "until" { publish() } }
        .onChange(of: timeZone) { _, _ in if endMode == "until" { publish() } }
    }

    private func publishing<Value>(_ value: Binding<Value>) -> Binding<Value> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; publish() })
    }
    private var unit: String {
        switch frequency {
        case "DAILY": interval == 1 ? "day" : "days"
        case "WEEKLY": interval == 1 ? "week" : "weeks"
        case "MONTHLY": interval == 1 ? "month" : "months"
        default: interval == 1 ? "year" : "years"
        }
    }
    private func load() {
        guard !loaded else { return }
        custom = rules.joined(separator: "\n")
        if rules.isEmpty { frequency = "NONE" }
        else if rules.count == 1, let rule = rules.first, rule.hasPrefix("RRULE:") {
            let pairs = rule.dropFirst(6).split(separator: ";").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
            let fields = Dictionary(pairs.filter { $0.count == 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
            let supported = Set(["FREQ", "INTERVAL", "BYDAY", "COUNT"])
            if Set(fields.keys).isSubset(of: supported), let freq = fields["FREQ"], ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].contains(freq),
               fields["BYDAY"] == nil || freq == "WEEKLY" && (fields["BYDAY"]?.split(separator: ",").allSatisfy { dayCodes.contains(String($0)) } == true) {
                frequency = freq
                interval = max(1, Int(fields["INTERVAL"] ?? "1") ?? 1)
                weekdays = Set((fields["BYDAY"] ?? "").split(separator: ",").map(String.init))
                if let value = fields["COUNT"], let number = Int(value) { count = max(1, number); endMode = "count" }
            } else { frequency = "CUSTOM" }
        } else { frequency = "CUSTOM" }
        loaded = true
    }
    private func publish() {
        guard loaded else { return }
        if frequency == "NONE" { rules = []; return }
        if frequency == "CUSTOM" {
            rules = custom.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return
        }
        var fields = ["FREQ=\(frequency)"]
        if interval > 1 { fields.append("INTERVAL=\(interval)") }
        if frequency == "WEEKLY", !weekdays.isEmpty { fields.append("BYDAY=" + dayCodes.filter(weekdays.contains).joined(separator: ",")) }
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
        rules = ["RRULE:" + fields.joined(separator: ";")]
    }
}
