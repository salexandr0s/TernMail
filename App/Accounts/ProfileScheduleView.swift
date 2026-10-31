import MailStore
import SwiftUI

struct ProfileScheduleView: View {
    @Binding var schedule: ProfileNotificationSchedule
    private typealias Mode = ProfileNotificationSchedule.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                Text("Notifications")
                    .frame(width: Tokens.Settings.editorLabelWidth, alignment: .leading)
                Picker("Notification schedule", selection: $schedule.mode) {
                    Text("Any time").tag(Mode.unrestricted)
                    Text("Off").tag(Mode.off)
                    Text("Every day").tag(Mode.everyDay)
                    Text("Weekdays").tag(Mode.weekdays)
                    Text("Custom days").tag(Mode.custom)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if schedule.mode == .custom {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    ForEach(ISOWeekday.allCases, id: \.rawValue) { day in
                        rangeEditor(title: weekdayName(day), day: day)
                    }
                }
            } else if schedule.mode == .everyDay || schedule.mode == .weekdays {
                rangeEditor(title: "Hours", day: nil)
            }

            Text(scheduleHelp)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Tokens.Settings.editorLabelWidth + Tokens.Space.s3)
        }
    }

    private var scheduleHelp: String {
        switch schedule.mode {
        case .unrestricted: "Notify at any time."
        case .off: "Mail still syncs. Notifications are off."
        default: "Uses this Mac's time zone. Split overnight hours at midnight."
        }
    }

    private func rangeEditor(title: String, day: ISOWeekday?) -> some View {
        let accessibilityDay = day == nil ? (schedule.mode == .weekdays ? "weekdays" : "every day") : title
        return HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Text(title)
                .frame(width: Tokens.Settings.editorLabelWidth, alignment: .leading)
                .padding(.top, Tokens.Space.s1)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                if schedule.ranges(day).isEmpty {
                    HStack {
                        Text("No notifications").foregroundStyle(.secondary)
                        Spacer(minLength: Tokens.Space.s2)
                        addHoursButton(title: accessibilityDay, day: day)
                    }
                    .frame(minHeight: Tokens.Settings.rowHeight)
                }
                ForEach(schedule.ranges(day).indices, id: \.self) { index in
                    // Dot syntax on a binding can't reach a subscript, so these pass the key path.
                    HStack(spacing: Tokens.Space.s2) {
                        DatePicker("From", selection: $schedule[dynamicMember: \.[day, range: index].startTime], displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Start time for \(accessibilityDay), range \(index + 1)")
                        Text("–").foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        DatePicker("To", selection: $schedule[dynamicMember: \.[day, range: index].endTime], displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("End time for \(accessibilityDay), range \(index + 1)")
                        Spacer(minLength: 0)
                        Button {
                            var values = schedule.ranges(day)
                            values.remove(at: index)
                            schedule.setRanges(values, day: day)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove these hours")
                        .accessibilityLabel("Remove hours for \(accessibilityDay), range \(index + 1)")
                        if index == 0 { addHoursButton(title: accessibilityDay, day: day) }
                        else { Color.clear.frame(width: Tokens.Control.icon).accessibilityHidden(true) }
                    }
                    .frame(minHeight: Tokens.Settings.rowHeight)
                }
            }
        }
    }

    private func addHoursButton(title: String, day: ISOWeekday?) -> some View {
        Button {
            var values = schedule.ranges(day)
            values.append(DailyTimeRange(startMinute: 9 * 60, endMinute: 17 * 60))
            schedule.setRanges(values, day: day)
        } label: {
            Image(systemName: "plus.circle")
        }
        .buttonStyle(.borderless)
        .help("Add hours")
        .accessibilityLabel("Add hours for \(title)")
    }

    private func weekdayName(_ day: ISOWeekday) -> String {
        let names = Calendar.autoupdatingCurrent.weekdaySymbols
        return names[day.rawValue % 7]
    }
}
