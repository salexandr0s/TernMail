import SwiftUI

/// What a sidebar row stands for. Calendar rows highlight and open their
/// settings; agenda rows select the event in the grid.
enum CalendarSidebarItem: Hashable {
    case calendar(String)
    case event(String)
}

struct CalendarSidebar: View {
    @Bindable var model: CalendarModel
    let manage: () -> Void
    let connect: (String) -> Void
    @State private var selection: CalendarSidebarItem?

    /// Room for the compact popover: the mini month, a row per calendar and
    /// agenda entry plus headers, capped so it never outgrows the window.
    static func popoverHeight(for model: CalendarModel) -> CGFloat {
        let agenda = model.presentation?.day(model.date)?.events.count
            ?? CalendarLayout.events(model.events, on: model.date, calendar: model.calendar).count
        let rows = model.calendars.isEmpty ? 0 : CGFloat(model.calendars.count + max(agenda, 1) + model.accounts.count + 1)
        let height = CalendarMiniMonth.height + rows * Tokens.Settings.rowHeight + Tokens.Space.s16
        return min(max(height, Tokens.Popover.maxListHeight), Tokens.Calendar.activityHeight)
    }

    var body: some View {
        List(selection: $selection) {
            CalendarMiniMonth(date: $model.date, calendar: model.calendar)
                .listRowInsets(EdgeInsets(top: Tokens.Space.s2, leading: Tokens.Space.s2, bottom: Tokens.Space.s2, trailing: Tokens.Space.s2))
                .selectionDisabled()
            // Until a calendar loads, the main area asks once for every account.
            if !model.calendars.isEmpty {
                ForEach(model.accounts) { account in
                    Section(account.title) {
                        let calendars = model.calendars.filter { $0.accountID == account.id }
                        if calendars.isEmpty || model.connectionState(for: account.id).issue != nil {
                            CalendarConnectionControl(model: model, account: account, connect: connect).selectionDisabled()
                        }
                        ForEach(calendars) { calendar in
                            calendarRow(calendar).tag(CalendarSidebarItem.calendar(calendar.id))
                        }
                    }
                }
                Section {
                    agendaRows
                } header: {
                    HStack {
                        Text(calendarDayTitle)
                        Spacer()
                        Text(CalendarLayout.format(model.date, style: .dateTime.month(.abbreviated).day(), calendar: model.calendar))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: CalendarSidebarItem.self) { items in
            if items.contains(where: { if case .event = $0 { true } else { false } }) {
                Button("Open Event") { open(items) }
            }
            Button("Calendar Settings…", action: manage)
        } primaryAction: { items in
            open(items)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.calendars.isEmpty {
                Button(action: manage) { Label("Manage Calendars…", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.borderless).controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Space.s3).padding(.vertical, Tokens.Space.s2)
                    .background(.bar)
            }
        }
        .onChange(of: selection) { _, item in
            if case .event(let id) = item { model.selectedEventID = id }
        }
        .onChange(of: model.selectedEventID) { _, id in
            if let id, agendaEvents.contains(where: { $0.id == id }) { selection = .event(id) }
            else if case .event = selection { selection = nil }
        }
        .accessibilityLabel("Calendars and daily agenda")
    }

    private func calendarRow(_ calendar: CalendarDisplayCalendar) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            Toggle(calendar.title, isOn: model.visibility(of: calendar))
                .toggleStyle(.checkbox).labelsHidden().tint(calendar.color)
            Text(calendar.title).lineLimit(1)
            Spacer(minLength: 0)
            if !calendar.canWrite {
                Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Read only")
            }
        }
        .help(calendar.title)
    }

    private var agendaEvents: [CalendarDisplayEvent] {
        if let presentation = model.presentation, presentation.matches(model.calendar) {
            return presentation.day(model.date)?.events ?? []
        }
        return CalendarLayout.events(model.events, on: model.date, calendar: model.calendar)
    }

    @ViewBuilder private var agendaRows: some View {
        let events = agendaEvents
        if events.isEmpty {
            Text(model.isLoading ? "Loading events…" : "No events shown for this day.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .selectionDisabled()
        } else {
            ForEach(events) { event in
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .fill(event.color).frame(width: Tokens.Space.s1)
                    VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                        Text(event.title).font(.callout.weight(.medium)).lineLimit(2)
                        Text(event.isAllDay ? "All day" : timeRange(event))
                            .font(.caption).foregroundStyle(.secondary)
                        if let location = event.event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Tokens.Space.s1)
                .ternHover()
                .tag(CalendarSidebarItem.event(event.id))
                .draggable(CalendarEventTransfer(event))
                .help("Open \(event.title)")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(model.selectedEventID == event.id ? .isSelected : [])
            }
        }
    }

    private func open(_ items: Set<CalendarSidebarItem>) {
        guard let item = items.first else { return }
        switch item {
        case .event(let id):
            guard let event = model.events.first(where: { $0.id == id }) else { return }
            model.selectedEventID = id
            model.edit(event)
        case .calendar:
            manage()
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

/// An account's calendar status and the action that fixes it. In the sidebar
/// the section header names the account; the main area's prompt shows it as
/// a row with the account's name and address, and keeps one Retry and one
/// Cancel Sign-In below its rows, since both act on every account.
struct CalendarConnectionControl: View {
    let model: CalendarModel
    let account: CalendarAccountOption
    let connect: (String) -> Void
    var showsAccount = false
    @Environment(AppModel.self) private var app

    var body: some View {
        if showsAccount {
            HStack(spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                    Text(account.title).font(.headline)
                    // Two accounts of one person share a display name.
                    if !account.email.isEmpty, account.email != account.title {
                        Text(account.email).font(.callout).foregroundStyle(.secondary)
                    }
                    status
                }
                Spacer(minLength: Tokens.Space.s2)
                action
            }
        } else {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                status
                action
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var status: some View {
        let state = model.connectionState(for: account.id)
        if let issue = state.issue {
            Text(issue.message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if state.isEnabled {
            Text("Connected. Google returned no calendars for this account.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var action: some View {
        let state = model.connectionState(for: account.id)
        if app.isSigningIn, !showsAccount {
            Button("Cancel Sign-In") { app.auth.cancelSignIn() }
                .buttonStyle(.bordered)
        } else if state.needsAuthorization {
            let verb = state.issue == nil ? "Connect" : "Reconnect"
            Button(showsAccount ? verb : "\(verb) Google Calendar") { connect(account.id) }
                .buttonStyle(.bordered)
                .disabled(model.isLoading || app.isSigningIn)
                // The address tells apart accounts that share a display name.
                .accessibilityLabel("\(verb) Google Calendar for \(account.email.isEmpty ? account.title : account.email)")
                // Voice Control users say the words on the button.
                .accessibilityInputLabels([verb, "\(verb) Google Calendar"])
        } else if !showsAccount {
            Button("Retry", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .buttonStyle(.bordered)
                .disabled(model.isLoading)
        }
    }
}
