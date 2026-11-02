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
        let agenda = (model.sidebarPresentation?.agenda(on: model.date, calendar: model.calendar)
            ?? CalendarLayout.events(model.sidebarEvents, on: model.date, calendar: model.calendar)).count
        let rows = model.calendars.isEmpty ? 0 : CGFloat(model.calendars.count + max(agenda, 1) + model.accounts.count + 1)
        let height = CalendarMiniMonth.height + rows * Tokens.Space.s10 + Tokens.Space.s16 + Tokens.Space.s6
        return min(max(height, Tokens.Popover.maxListHeight), Tokens.Calendar.activityHeight)
    }

    var body: some View {
        let monthEvents = self.monthEvents
        let monthCounts = Dictionary(grouping: monthEvents, by: \.calendarKey).mapValues(\.count)
        let agenda = agendaEvents
        let upcoming = agenda.isEmpty ? upcomingEvents(in: monthEvents) : []
        List(selection: $selection) {
            CalendarMiniMonth(date: $model.date, calendar: model.calendar, events: model.sidebarEvents,
                presentation: model.sidebarPresentation)
                .padding(.horizontal, Tokens.Space.s2)
                .padding(.vertical, Tokens.Space.s3)
                .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .ternOutline(radius: Tokens.Radius.md)
                .listRowInsets(EdgeInsets(top: Tokens.Space.s3, leading: Tokens.Space.s2, bottom: Tokens.Space.s3, trailing: Tokens.Space.s2))
                .selectionDisabled()
            if !model.calendars.isEmpty {
                Section {
                    ForEach(model.accounts) { account in
                        if model.accounts.count > 1 {
                            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                                Text(account.title).font(.callout.bold())
                                if !account.email.isEmpty, account.email != account.title {
                                    Text(account.email).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).help(account.email)
                                }
                            }
                            .padding(.top, Tokens.Space.s3)
                            .selectionDisabled()
                        }
                        let calendars = model.calendars.filter { $0.accountID == account.id }
                        if calendars.isEmpty || model.connectionState(for: account.id).issue != nil {
                            CalendarConnectionControl(model: model, account: account, connect: connect).selectionDisabled()
                        }
                        ForEach(calendars) { calendar in
                            calendarRow(calendar, count: monthCounts[calendar.id] ?? 0)
                                .tag(CalendarSidebarItem.calendar(calendar.id))
                        }
                    }
                } header: {
                    HStack {
                        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                            Text("Calendars").font(.headline)
                            Text("\(model.calendars.filter(\.isVisible).count) of \(model.calendars.count) visible")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Manage Calendars", systemImage: "slider.horizontal.3", action: manage)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Manage Calendars")
                    }
                    .padding(.top, Tokens.Space.s3)
                    .textCase(nil)
                }
                Section {
                    agendaRows(agenda)
                } header: {
                    agendaHeading(count: agenda.count)
                }
                if !upcoming.isEmpty {
                    Section("Later this month") {
                        ForEach(upcoming) { event in
                            eventRow(event, showsDate: true)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Calendars and daily agenda")
        .contextMenu(forSelectionType: CalendarSidebarItem.self) { items in
            if items.contains(where: { if case .event = $0 { true } else { false } }) {
                Button("Open Event") { open(items) }
            }
            Button("Calendar Settings…", action: manage)
        } primaryAction: { items in
            open(items)
        }
        .safeAreaBar(edge: .bottom) {
            SidebarFooter(accessibilityPrefix: "calendar.sidebar") {
                CalendarSidebarSyncStatus(model: model)
            }
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .onChange(of: selection) { _, item in
            if case .event(let id) = item, let event = event(withID: id) {
                if !agendaEvents.contains(where: { $0.id == id }) { model.date = event.start }
                model.selectedEventID = id
            }
        }
        .onChange(of: model.selectedEventID) { _, id in
            if let id, agendaEvents.contains(where: { $0.id == id }) { selection = .event(id) }
            else if case .event = selection { selection = nil }
        }
    }

    private func calendarRow(_ calendar: CalendarDisplayCalendar, count: Int) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            Toggle(calendar.title, isOn: model.visibility(of: calendar))
                .toggleStyle(.checkbox).labelsHidden().tint(calendar.color)
                .accessibilityValue(calendar.isVisible ? "Visible" : "Hidden")
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1_5) {
                    Circle().fill(calendar.color)
                        .frame(width: Tokens.Space.s2, height: Tokens.Space.s2)
                        .accessibilityHidden(true)
                    Text(calendar.title).font(.callout.bold()).lineLimit(2)
                }
                .foregroundStyle(calendar.isVisible ? .primary : .secondary)
                Text(calendar.isVisible ? (calendar.canWrite ? "Can edit" : "Read only") : "Hidden")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if calendar.isVisible, model.sidebarPresentation != nil, !model.sidebarHasStaleEvents {
                Text(count, format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Space.s2)
                    .padding(.vertical, Tokens.Space.s1)
                    .background(Tokens.Surface.primary, in: Capsule())
                    .accessibilityLabel(count == 1 ? "1 event this month" : "\(count) events this month")
                    .help(count == 1 ? "1 event this month" : "\(count) events this month")
            }
        }
        .padding(.vertical, Tokens.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .ternHover(isEnabled: selection != .calendar(calendar.id))
        .help(calendar.title)
    }

    private func agendaHeading(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(calendarDayTitle).font(.title3.bold()).foregroundStyle(.primary)
                Text(CalendarLayout.format(model.date, style: .dateTime.month(.wide).day(), calendar: model.calendar))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if count > 0 {
                Text(count == 1 ? "1 event" : "\(count) events")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Tokens.Space.s2)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var agendaEvents: [CalendarDisplayEvent] {
        model.sidebarPresentation?.agenda(on: model.date, calendar: model.calendar)
            ?? CalendarLayout.events(model.sidebarEvents, on: model.date, calendar: model.calendar)
    }

    private var monthEvents: [CalendarDisplayEvent] {
        guard let month = model.calendar.dateInterval(of: .month, for: model.date) else { return [] }
        return model.sidebarEvents.filter { $0.start < month.end && max($0.end, $0.start.addingTimeInterval(1)) > month.start }
    }

    private func upcomingEvents(in monthEvents: [CalendarDisplayEvent]) -> [CalendarDisplayEvent] {
        let start = model.calendar.startOfDay(for: model.date)
        guard let nextDay = model.calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return Array(monthEvents.filter { $0.start >= nextDay }.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }.prefix(3))
    }

    @ViewBuilder private func agendaRows(_ events: [CalendarDisplayEvent]) -> some View {
        if events.isEmpty {
            CalendarSidebarEmptyDay(model: model)
                .selectionDisabled()
        } else {
            ForEach(events) { event in
                eventRow(event)
            }
        }
    }

    private func eventRow(_ event: CalendarDisplayEvent, showsDate: Bool = false) -> some View {
        CalendarSidebarEventRow(event: event, calendar: model.calendar, showsDate: showsDate,
                                isSelected: selection == .event(event.id))
            .ternHover(isEnabled: selection != .event(event.id))
            .tag(CalendarSidebarItem.event(event.id))
            .draggable(CalendarEventTransfer(event))
            .help("Open \(event.title)")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(model.selectedEventID == event.id ? .isSelected : [])
    }

    private func event(withID id: String) -> CalendarDisplayEvent? {
        model.sidebarEvents.first { $0.id == id } ?? model.events.first { $0.id == id }
    }

    private func open(_ items: Set<CalendarSidebarItem>) {
        guard let item = items.first else { return }
        switch item {
        case .event(let id):
            guard let event = event(withID: id) else { return }
            if !agendaEvents.contains(where: { $0.id == id }) { model.date = event.start }
            model.selectedEventID = id
            model.edit(event)
        case .calendar:
            manage()
        }
    }

    private var calendarDayTitle: String {
        model.calendar.isDateInToday(model.date) ? "Today" : CalendarLayout.format(model.date, style: .dateTime.weekday(.wide), calendar: model.calendar)
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
