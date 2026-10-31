import SwiftUI

/// Preserves provider rules until the user chooses a replacement pattern.
struct CalendarRecurrenceControl: View {
    @Binding var rules: [String]
    var allDay = false
    var timeZone = TimeZone.autoupdatingCurrent
    /// Read once from `rules`. Edits write `rules` back; opening the editor
    /// doesn't, so rules it can't show stay as they were.
    @State private var selection: RecurrenceSelection
    /// `Calendar` weekday numbers for MO through SU: Sunday is 1.
    private let dayNumbers = [2, 3, 4, 5, 6, 7, 1]

    init(rules: Binding<[String]>, allDay: Bool = false, timeZone: TimeZone = .autoupdatingCurrent) {
        _rules = rules
        self.allDay = allDay
        self.timeZone = timeZone
        _selection = State(initialValue: RecurrenceSelection(rules: rules.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Picker("Repeat", selection: $selection.frequency) {
                Text("Never").tag("NONE")
                Text("Daily").tag("DAILY")
                Text("Weekly").tag("WEEKLY")
                Text("Monthly").tag("MONTHLY")
                Text("Yearly").tag("YEARLY")
                Text("Custom Rule").tag("CUSTOM")
            }
            if selection.frequency == "CUSTOM" {
                TextEditor(text: $selection.custom).font(.system(.caption, design: .monospaced))
                    .frame(minHeight: Tokens.Space.s16 + Tokens.Space.s2)
                    .accessibilityLabel("Recurrence rules")
                Text("One RRULE, RDATE or EXDATE per line. Existing custom rules are preserved.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if selection.frequency != "NONE" {
                Stepper("Every \(selection.interval) \(unit)", value: $selection.interval, in: 1...999)
                if selection.frequency == "WEEKLY" {
                    HStack(spacing: Tokens.Space.s1) {
                        ForEach(Array(RecurrenceSelection.dayCodes.enumerated()), id: \.element) { index, code in
                            Toggle(Calendar.autoupdatingCurrent.shortWeekdaySymbols[dayNumbers[index] - 1],
                                   isOn: $selection.weekdays.contains(code))
                            .toggleStyle(.button)
                            .accessibilityLabel(Calendar.autoupdatingCurrent.weekdaySymbols[dayNumbers[index] - 1])
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                Picker("Ends", selection: $selection.endMode) {
                    Text("Never").tag("never"); Text("After Occurrences").tag("count"); Text("On Date").tag("until")
                }
                if selection.endMode == "count" { Stepper("After ^[\(selection.count) event](inflect: true)", value: $selection.count, in: 1...9999) }
                if selection.endMode == "until" { DatePicker("Last Date", selection: $selection.until, displayedComponents: .date) }
            }
        }
        .onChange(of: selection) { _, _ in publish() }
        .onChange(of: allDay) { _, _ in if selection.endMode == "until" { publish() } }
        .onChange(of: timeZone) { _, _ in if selection.endMode == "until" { publish() } }
    }

    private var unit: String {
        switch selection.frequency {
        case "DAILY": selection.interval == 1 ? "day" : "days"
        case "WEEKLY": selection.interval == 1 ? "week" : "weeks"
        case "MONTHLY": selection.interval == 1 ? "month" : "months"
        default: selection.interval == 1 ? "year" : "years"
        }
    }

    private func publish() {
        rules = selection.rules(allDay: allDay, timeZone: timeZone)
    }
}
