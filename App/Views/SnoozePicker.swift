import SwiftUI

/// The Snooze menu: the presets that apply now, then Choose Date & Time.
struct SnoozeMenuItems: View {
    let options: [SnoozeSchedule.Option]
    let calendar: Calendar
    let onSnooze: (Date) -> Void
    let onChooseDate: () -> Void

    var body: some View {
        ForEach(options, id: \.preset) { option in
            Button(Self.title(for: option, calendar: calendar)) { onSnooze(option.wakeAt) }
        }
        if !options.isEmpty {
            Divider()
        }
        Button("Choose Date & Time…", action: onChooseDate)
    }

    /// "Later Today, 6:00 PM" or "Tomorrow, Thu 8:00 AM".
    static func title(for option: SnoozeSchedule.Option, calendar: Calendar) -> String {
        let name = switch option.preset {
        case .laterToday: "Later Today"
        case .tomorrow: "Tomorrow"
        case .thisWeekend: "This Weekend"
        case .nextWeek: "Next Week"
        }
        var style = Date.FormatStyle(
            locale: calendar.locale ?? .autoupdatingCurrent,
            calendar: calendar,
            timeZone: calendar.timeZone
        ).hour().minute()
        if option.preset != .laterToday {
            style = style.weekday(.abbreviated)
        }
        return "\(name), \(option.wakeAt.formatted(style))"
    }
}

/// Choose Date & Time: any moment after now.
struct SnoozeDateSheet: View {
    let onSnooze: (Date) -> Void
    let onCancel: () -> Void

    @State private var wakeAt: Date
    @State private var isInPast = false
    private let now: Date

    init(initial: Date, now: Date, onSnooze: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.now = now
        self.onSnooze = onSnooze
        self.onCancel = onCancel
        _wakeAt = State(initialValue: max(initial, now))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text("Snooze Until")
                .font(.headline)
            DatePicker("Date", selection: $wakeAt, in: now..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            DatePicker("Time", selection: $wakeAt, in: now..., displayedComponents: .hourAndMinute)
            if isInPast {
                Label("Choose a time later than now.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack(spacing: Tokens.Space.s3) {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Snooze") {
                    // The sheet may stay open past the chosen time.
                    if wakeAt > .now {
                        onSnooze(wakeAt)
                    } else {
                        isInPast = true
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Space.s6)
        .fixedSize()
        .onChange(of: wakeAt) { isInPast = false }
    }
}
