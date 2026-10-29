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
        ForEach(options, id: \.preset) { option in
            Button(Self.title(for: option, calendar: schedule.calendar)) { onSnooze(option.wakeAt) }
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
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "moon.zzz")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: Tokens.Control.avatarLarge, height: Tokens.Control.avatarLarge)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Snooze Until")
                        .font(.title3.weight(.semibold))
                }
            }
            .padding(Tokens.Space.s6)

            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                DatePicker("Date", selection: $wakeAt, in: now..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                Divider()
                DatePicker("Time", selection: $wakeAt, in: now..., displayedComponents: .hourAndMinute)
                    .accessibilityHint(isInPast ? "Choose a future time." : "Time to return to the Inbox")
                if isInPast {
                    Label("Choose a future time.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Tokens.Space.s4)
            .ternSurface()
            .padding(.horizontal, Tokens.Space.s6)
            .padding(.bottom, Tokens.Space.s6)

            Divider()
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
            .padding(Tokens.Space.s5)
            .background(Tokens.Surface.muted)
        }
        .frame(width: Tokens.Sheet.smallWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: wakeAt) { isInPast = false }
        .ternAnimation(value: isInPast)
    }
}
