import Foundation
import SwiftUI

struct CalendarRecurrenceDescription: View {
    let rules: [String]
    let allDay: Bool
    let calendar: Calendar

    private var selection: RecurrenceSelection {
        RecurrenceSelection(rules: rules, allDay: allDay, timeZone: calendar.timeZone)
    }

    var body: some View {
        let value = selection
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            switch value.frequency {
            case "DAILY": Text("Every ^[\(value.interval) day](inflect: true)")
            case "WEEKLY": Text("Every ^[\(value.interval) week](inflect: true)")
            case "MONTHLY": Text("Every ^[\(value.interval) month](inflect: true)")
            case "YEARLY": Text("Every ^[\(value.interval) year](inflect: true)")
            case "CUSTOM":
                DisclosureGroup("Custom repeating schedule") {
                    Text(rules.joined(separator: "\n")).textSelection(.enabled)
                }
            default: Text("Does not repeat")
            }
            if value.frequency != "CUSTOM" {
                if value.frequency == "WEEKLY", !value.weekdays.isEmpty {
                    let dayNumbers = [2, 3, 4, 5, 6, 7, 1]
                    let names = RecurrenceSelection.dayCodes.enumerated().compactMap { index, code in
                        value.weekdays.contains(code) ? calendar.weekdaySymbols[dayNumbers[index] - 1] : nil
                    }
                    Text(names.formatted(.list(type: .and)))
                }
                if value.endMode == "count" { Text("Ends after ^[\(value.count) occurrence](inflect: true)") }
                if value.endMode == "until" {
                    Text("Ends on \(CalendarLayout.format(value.until, style: .dateTime.year().month().day(), calendar: calendar))")
                }
            }
        }.font(.caption)
    }
}
