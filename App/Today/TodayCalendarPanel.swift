import SwiftUI

struct TodayCalendarPanel: View {
    @Bindable var dashboard: TodayDashboardModel
    let query: String
    @Environment(\.openSettings) private var openSettings

    private var events: [CalendarDisplayEvent] {
        dashboard.upcomingEvents.filter { query.isEmpty || [$0.title, $0.event.location ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    private var days: [Date] {
        Array(Set(events.map { dashboard.calendar.startOfDay(for: max($0.start, dashboard.selectedDateStart)) })).sorted()
    }

    var body: some View {
        TodayDashboardSection(title: "Calendar", symbol: "calendar") {
            CalendarMiniMonth(date: $dashboard.selectedDate, calendar: dashboard.calendar, events: dashboard.monthEvents)
            Divider()
            agenda
            status
        }
        .accessibilityIdentifier("today-calendar")
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                Text("Upcoming events").font(.subheadline.weight(.semibold))
                if dashboard.hasLoadedCalendar, dashboard.hasAvailableCalendars {
                    Text(events.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(events.count) events shown")
                }
            }
            Text("7 days from \(CalendarLayout.format(dashboard.selectedDate, style: .dateTime.month(.abbreviated).day(), calendar: dashboard.calendar))")
                .font(.caption).foregroundStyle(.secondary)
            if dashboard.calendarLoading && !dashboard.hasLoadedCalendar {
                TodayLoadingStatus("Loading events…")
            } else if !dashboard.hasLoadedCalendar {
                TodayCompactState(title: "Calendar not loaded", symbol: "calendar.badge.exclamationmark",
                    message: "Refresh to check the available events.")
            } else if !dashboard.hasAvailableCalendars {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    TodayCompactState(title: "No calendars available", symbol: "calendar",
                        message: "Connect Calendar or choose visible calendars for this profile.")
                    Button("Calendar Settings…") {
                        SettingsNavigationRequests.shared.request(.calendar)
                        openSettings()
                    }
                    .controlSize(.small)
                }
            } else if events.isEmpty {
                TodayCompactState(title: query.isEmpty ? "No available events" : "No matching events", symbol: "calendar",
                    message: query.isEmpty ? "Nothing is shown in this seven-day range." : "Try another search or select a different day.")
            } else {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    ForEach(days, id: \.self) { day in
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(dayTitle(day)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(events.filter { dashboard.calendar.isDate(max($0.start, dashboard.selectedDateStart), inSameDayAs: day) }) { event in
                                Button { dashboard.openEvent(event) } label: {
                                    TodayAgendaEventRow(event: event, calendar: dashboard.calendar,
                                        accountTitle: dashboard.context.accounts.first { $0.id == event.accountID }?.title)
                                }
                                .buttonStyle(.plain).ternHover()
                                .accessibilityLabel("Open event: \(event.title)")
                                .accessibilityIdentifier("today-event-\(event.id)")
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-agenda")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if dashboard.calendarLoading && dashboard.hasLoadedCalendar { TodayLoadingStatus("Updating events…") }
            if let error = dashboard.calendarError {
                TodayInlineWarning(error, retry: { Task { await dashboard.refreshCalendar() } })
            }
            if let warning = dashboard.calendarCoverageWarning { TodayInlineWarning(warning) }
            TodayCoverageNote(summary: "Available calendar data only.", details: dashboard.calendarCoverage, label: "Calendar data")
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let date = CalendarLayout.format(day, style: .dateTime.month(.abbreviated).day(), calendar: dashboard.calendar)
        if dashboard.calendar.isDateInToday(day) { return "Today · \(date)" }
        if dashboard.calendar.isDateInTomorrow(day) { return "Tomorrow · \(date)" }
        return CalendarLayout.format(day, style: .dateTime.weekday(.wide).month(.abbreviated).day(), calendar: dashboard.calendar)
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

private extension TodayDashboardModel {
    var selectedDateStart: Date { calendar.startOfDay(for: selectedDate) }
}
