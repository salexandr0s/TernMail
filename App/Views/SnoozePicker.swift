import SwiftUI

/// The Snooze menu: the presets that apply now, then Choose Date & Time.
/// The menu bar and the toolbar draw their menus before they open, so the
/// presets follow `MinuteClock` rather than the time the menu was drawn.
struct SnoozeMenuItems: View {
    let onSnooze: (Date) -> Void
    let onChooseDate: () -> Void
    private let schedule = SnoozeSchedule()

    var body: some View {
        let options = schedule.options(now: MinuteClock.shared.now)
        Group {
            ForEach(options, id: \.preset) { option in
                Button(Self.title(for: option, calendar: schedule.calendar), systemImage: Self.symbol(for: option.preset)) {
                    onSnooze(option.wakeAt)
                }
            }
            if !options.isEmpty {
                Divider()
            }
            Button("Choose Date & Time…", systemImage: "calendar.badge.clock", action: onChooseDate)
        }
        .labelStyle(.titleAndIcon)
    }

    private static func symbol(for preset: SnoozeSchedule.Preset) -> String {
        switch preset {
        case .laterToday: "sun.horizon"
        case .tomorrow: "sunrise"
        case .thisWeekend: "calendar"
        case .nextWeek: "calendar.badge.clock"
        }
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

/// The time to the minute, for menus drawn before they open. `now` changes
/// at the start of each minute, so a view that reads it draws again.
@MainActor
@Observable
final class MinuteClock {
    static let shared = MinuteClock()
    private(set) var now = Date.now

    private init() {
        Task { [weak self] in
            while true {
                let seconds = 60 - Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                try? await Task.sleep(for: .seconds(seconds))
                guard let self else { return }
                now = .now
            }
        }
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
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(title: "Snooze Until", systemImage: "moon.zzz")

            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                DatePicker("Date", selection: $wakeAt, in: now..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                Divider()
                HStack {
                    Text("Time")
                        .foregroundStyle(.secondary)
                    Spacer()
                    DatePicker("Time", selection: $wakeAt, in: now..., displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .accessibilityHint(isInPast ? "Choose a future time." : "Time to return to the Inbox")
                }
                if isInPast {
                    Label("Choose a future time.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.bottom, Tokens.Space.s5)

            PopupFooter {
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: Tokens.Sheet.smallWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: wakeAt) { isInPast = false }
        .ternAnimation(value: isInPast)
    }
}
