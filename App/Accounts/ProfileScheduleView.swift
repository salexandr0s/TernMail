import MailStore
import SwiftUI

struct ProfileScheduleView: View {
    @Binding var schedule: ProfileNotificationSchedule
    private enum Mode: String, CaseIterable { case unrestricted, off, everyDay, weekdays, custom }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Picker("Notification schedule", selection: Binding(get: { mode }, set: { mode in
                let hours = [DailyTimeRange(startMinute: 9 * 60, endMinute: 17 * 60)]
                schedule = switch mode {
                case .unrestricted: .unrestricted
                case .off: .off
                case .everyDay: .everyDay(hours)
                case .weekdays: .weekdays(hours)
                case .custom: .custom(Dictionary(uniqueKeysWithValues: ISOWeekday.allCases.map { ($0, hours) }))
                }
            })) {
                Text("Any time").tag(Mode.unrestricted)
                Text("Off").tag(Mode.off)
                Text("Every day").tag(Mode.everyDay)
                Text("Weekdays").tag(Mode.weekdays)
                Text("Custom days").tag(Mode.custom)
            }
            ScrollView {
                if mode == .custom {
                    ForEach(ISOWeekday.allCases, id: \.rawValue) { day in
                        rangeEditor(title: weekdayName(day), day: day)
                    }
                } else if mode == .everyDay || mode == .weekdays {
                    rangeEditor(title: mode == .weekdays ? "Monday–Friday" : "Every day", day: nil)
                }
            }
            Text("Times follow this Mac's local time zone. For overnight hours, add one range before midnight and another on the next day.")
                .font(.caption).foregroundStyle(.secondary)
            if !schedule.isValid { Text("Each range must end after it starts.").font(.caption).foregroundStyle(.red) }
        }
    }

    private func rangeEditor(title: String, day: ISOWeekday?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Add Hours", systemImage: "plus") {
                    var values = ranges(day)
                    values.append(DailyTimeRange(startMinute: 9 * 60, endMinute: 17 * 60))
                    setRanges(values, day: day)
                }
            }
            ForEach(Array(ranges(day).enumerated()), id: \.offset) { index, _ in
                HStack {
                    DatePicker("From", selection: timeBinding(day: day, index: index, end: false), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: timeBinding(day: day, index: index, end: true), displayedComponents: .hourAndMinute)
                    Button("Remove", systemImage: "minus.circle") {
                        var values = ranges(day); values.remove(at: index); setRanges(values, day: day)
                    }.labelStyle(.iconOnly).help("Remove these hours")
                }
            }
            if ranges(day).isEmpty { Text("No notifications").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, Tokens.Space.s2)
    }

    private var mode: Mode {
        switch schedule {
        case .unrestricted: .unrestricted
        case .off: .off
        case .everyDay: .everyDay
        case .weekdays: .weekdays
        case .custom: .custom
        }
    }
    private func ranges(_ day: ISOWeekday?) -> [DailyTimeRange] {
        switch schedule {
        case .everyDay(let values), .weekdays(let values): values
        case .custom(let days): day.flatMap { days[$0] } ?? []
        default: []
        }
    }
    private func setRanges(_ values: [DailyTimeRange], day: ISOWeekday?) {
        switch schedule {
        case .everyDay: schedule = .everyDay(values)
        case .weekdays: schedule = .weekdays(values)
        case .custom(var days): if let day { days[day] = values }; schedule = .custom(days)
        default: break
        }
    }
    private func timeBinding(day: ISOWeekday?, index: Int, end: Bool) -> Binding<Date> {
        Binding(get: {
            let values = ranges(day)
            guard values.indices.contains(index) else { return .now }
            let minute = end ? values[index].endMinute : values[index].startMinute
            return Calendar.autoupdatingCurrent.date(from: DateComponents(year: 2001, month: 1, day: 15,
                hour: (minute / 60) % 24, minute: minute % 60)) ?? .now
        }, set: { date in
            var values = ranges(day)
            guard values.indices.contains(index) else { return }
            let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if end { values[index].endMinute = minute == 0 ? 1440 : minute }
            else { values[index].startMinute = minute }
            setRanges(values, day: day)
        })
    }
    private func weekdayName(_ day: ISOWeekday) -> String {
        let names = Calendar.autoupdatingCurrent.weekdaySymbols
        return names[day.rawValue % 7]
    }
}
