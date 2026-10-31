import SwiftUI

struct CalendarSidebar: View {
    @Bindable var model: CalendarModel
    let manage: () -> Void
    let connect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                CalendarMiniMonth(date: $model.date, calendar: model.calendar)
                Divider()
                calendarList
                Divider()
                agenda
            }
            .padding(Tokens.Space.s4)
        }
        .background(Tokens.Surface.muted)
        .accessibilityLabel("Calendars and daily agenda")
    }

    private var calendarList: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                Text("Calendars").font(.headline)
                Spacer()
                Button(action: manage) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("Manage calendars").accessibilityLabel("Manage calendars")
            }
            ForEach(model.accounts) { account in
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text(account.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .lineLimit(1).help(account.title)
                    let calendars = model.calendars.filter { $0.accountID == account.id }
                    if calendars.isEmpty || model.connectionState(for: account.id).issue != nil {
                        CalendarConnectionControl(model: model, account: account, connect: connect)
                    }
                    ForEach(calendars) { calendar in
                        Toggle(isOn: Binding(get: { calendar.isVisible }, set: { model.setVisible(id: calendar.id, visible: $0) })) {
                            HStack(spacing: Tokens.Space.s2) {
                                Circle().fill(calendar.color).frame(width: Tokens.Space.s2, height: Tokens.Space.s2)
                                Text(calendar.title).lineLimit(1)
                                Spacer(minLength: 0)
                                if !calendar.canWrite {
                                    Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary)
                                        .accessibilityLabel("Read only")
                                }
                            }
                        }
                        .toggleStyle(.checkbox).padding(.vertical, Tokens.Space.s1)
                        .help(calendar.title).contextMenu { Button("Calendar settings…", action: manage) }
                    }
                }
            }
        }
    }

    private var agenda: some View {
        let events = CalendarLayout.events(model.events, on: model.date, calendar: model.calendar)
        return VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(calendarDayTitle).font(.headline)
                Text(CalendarLayout.format(model.date, style: .dateTime.month(.wide).day(), calendar: model.calendar))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if events.isEmpty {
                Text(model.isLoading ? "Loading events…" : "No events shown for this day.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(events) { event in
                    Button { model.selectedEventID = event.id; model.edit(event) } label: {
                        HStack(alignment: .top, spacing: Tokens.Space.s2) {
                            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                                .fill(event.color).frame(width: Tokens.Space.s1)
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(event.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                                Text(event.isAllDay ? "All day" : timeRange(event))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let location = event.event.location, !location.isEmpty {
                                    Label(location, systemImage: "mappin.and.ellipse")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Tokens.Space.s2)
                        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                                .strokeBorder(model.selectedEventID == event.id ? Color.accentColor : Color.clear,
                                              lineWidth: Tokens.Border.focus)
                        }
                    }.buttonStyle(.plain).help("Open \(event.title)")
                }
            }
        }
    }

    private var calendarDayTitle: String {
        model.calendar.isDateInToday(model.date) ? "Today" : CalendarLayout.format(model.date, style: .dateTime.weekday(.wide), calendar: model.calendar)
    }

    private func timeRange(_ event: CalendarDisplayEvent) -> String {
        let formatter = DateIntervalFormatter()
        formatter.calendar = model.calendar
        formatter.timeZone = model.calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: event.start, to: event.end)
    }
}

struct CalendarConnectionControl: View {
    let model: CalendarModel
    let account: CalendarAccountOption
    let connect: (String) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let state = model.connectionState(for: account.id)
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if let issue = state.issue {
                Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.isEnabled {
                Text("Connected. Google returned no calendars for this account.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.needsAuthorization {
                Button(state.issue == nil ? "Connect Google Calendar" : "Reconnect Google Calendar") { connect(account.id) }
                    .buttonStyle(.bordered)
            } else {
                Button("Retry", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .buttonStyle(.bordered)
            }
        }
        .font(.callout)
        .disabled(model.isLoading || app.isSigningIn)
    }
}
