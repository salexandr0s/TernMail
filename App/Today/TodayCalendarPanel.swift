import SwiftUI

struct TodayCalendarPanel: View {
    @Bindable var dashboard: TodayDashboardModel
    let query: String
    @Environment(\.openSettings) private var openSettings

    private struct Day: Identifiable {
        let id: Date
        var events: [CalendarDisplayEvent]
    }

    var body: some View {
        // One read of the prepared lists and of the calendar per body.
        let agenda = dashboard.agenda, calendar = dashboard.calendar
        TodayDashboardSection(title: "Calendar", symbol: "calendar", updatingLabel: "Updating events…",
            isUpdating: dashboard.calendarLoading && agenda.isLoaded) {
            CalendarMiniMonth(date: $dashboard.selectedDate, calendar: calendar, events: agenda.monthEvents)
            Divider()
            upcoming(agenda, calendar: calendar)
            status
        }
        .accessibilityIdentifier("today-calendar")
    }

    /// Events keep their order and are grouped by the day they are listed under.
    /// One that began before the selected day is listed under that day.
    private func days(_ events: [CalendarDisplayEvent], calendar: Calendar) -> [Day] {
        let first = calendar.startOfDay(for: dashboard.selectedDate)
        var days: [Day] = [], index: [Date: Int] = [:]
        for event in events {
            let day = calendar.startOfDay(for: max(event.start, first))
            if let position = index[day] { days[position].events.append(event) }
            else { index[day] = days.count; days.append(Day(id: day, events: [event])) }
        }
        return days.sorted { $0.id < $1.id }
    }

    private func upcoming(_ agenda: TodayAgenda, calendar: Calendar) -> some View {
        let events = agenda.upcomingEvents.filter { query.isEmpty || [$0.title, $0.event.location ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) } }
        let days = days(events, calendar: calendar)
        let titles = Dictionary(dashboard.context.accounts.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                Text("Upcoming events").font(.subheadline.weight(.semibold))
                if agenda.isLoaded, agenda.hasCalendars {
                    Text(events.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(events.count) events shown")
                }
            }
            Text("7 days from \(CalendarLayout.format(dashboard.selectedDate, style: .dateTime.month(.abbreviated).day(), calendar: calendar))")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                if dashboard.calendarLoading && !agenda.isLoaded {
                    TodayLoadingStatus("Loading events…").ternDelayedLoading().ternTransition(.fade)
                } else if !agenda.isLoaded {
                    TodayCompactState(title: "Calendar not loaded", symbol: "calendar.badge.exclamationmark",
                        message: "Refresh to check the available events.")
                        .ternTransition(.fade)
                } else if !agenda.hasCalendars {
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        TodayCompactState(title: "No calendars available", symbol: "calendar",
                            message: "Connect Calendar or choose visible calendars for this profile.")
                        Button("Calendar Settings…") {
                            SettingsNavigationRequests.shared.request(.calendar)
                            openSettings()
                        }
                        .controlSize(.small)
                    }
                    .ternTransition(.fade)
                } else if events.isEmpty {
                    TodayCompactState(title: query.isEmpty ? "No available events" : "No matching events", symbol: "calendar",
                        message: query.isEmpty ? "Nothing is shown in this seven-day range." : "Try another search or select a different day.")
                        .ternTransition(.fade)
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        ForEach(days) { day in
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(dayTitle(day.id, calendar: calendar)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(day.events) { event in
                                    Button { dashboard.openEvent(event) } label: {
                                        TodayAgendaEventRow(event: event, calendar: calendar, accountTitle: titles[event.accountID])
                                    }
                                    .buttonStyle(.plain).ternHover()
                                    .accessibilityLabel("Open event: \(event.title)")
                                    .accessibilityIdentifier("today-event-\(event.id)")
                                }
                            }
                        }
                    }
                    .ternTransition(.fade)
                }
            }
            .ternAnimation(value: TodayContentKey(
                states: [dashboard.calendarLoading && !agenda.isLoaded, agenda.isLoaded, agenda.hasCalendars],
                ids: events.map(\.id)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-agenda")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if let error = dashboard.calendarError {
                TodayInlineWarning(error, retry: { Task { await dashboard.refreshCalendar() } })
            }
            if let warning = dashboard.calendarCoverageWarning { TodayInlineWarning(warning) }
            TodayCoverageNote(summary: "Available calendar data only.", details: dashboard.calendarCoverage, label: "Calendar data")
        }
    }

    private func dayTitle(_ day: Date, calendar: Calendar) -> String {
        let date = CalendarLayout.format(day, style: .dateTime.month(.abbreviated).day(), calendar: calendar)
        if calendar.isDateInToday(day) { return "Today · \(date)" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow · \(date)" }
        return CalendarLayout.format(day, style: .dateTime.weekday(.wide).month(.abbreviated).day(), calendar: calendar)
    }
}

private struct TodayAgendaEventRow: View {
    let event: CalendarDisplayEvent
    let calendar: Calendar
    let accountTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            RoundedRectangle(cornerRadius: Tokens.Space.s0_5).fill(event.color)
                .frame(width: Tokens.Space.s1)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    Text(event.title).font(.callout.weight(.medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if event.isPending {
                        Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Waiting to sync")
                    }
                }
                Text(timeDescription).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let accountTitle { Text(accountTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let location = event.event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, Tokens.Space.s1_5)
        .padding(.horizontal, Tokens.Space.s1)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
    }

    private var timeDescription: String {
        if event.isAllDay {
            let last = calendar.date(byAdding: .day, value: -1, to: event.end) ?? event.start
            guard !calendar.isDate(event.start, inSameDayAs: last) else { return "All day" }
            return "All day · \(CalendarLayout.format(event.start, style: .dateTime.month(.abbreviated).day(), calendar: calendar))–\(CalendarLayout.format(last, style: .dateTime.month(.abbreviated).day(), calendar: calendar))"
        }
        let start = CalendarLayout.format(event.start, style: .dateTime.hour().minute(), calendar: calendar)
        let end = CalendarLayout.format(event.end, style: .dateTime.hour().minute(), calendar: calendar)
        if calendar.isDate(event.start, inSameDayAs: event.end) { return "\(start)–\(end)" }
        return "\(CalendarLayout.format(event.start, style: .dateTime.month(.abbreviated).day(), calendar: calendar)) \(start)–\(CalendarLayout.format(event.end, style: .dateTime.month(.abbreviated).day(), calendar: calendar)) \(end)"
    }
}
