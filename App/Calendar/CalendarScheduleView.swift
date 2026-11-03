import SwiftUI

struct CalendarScheduleView: View {
    @Environment(\.calendarPresentation) private var presentation
    @Environment(\.calendarIdentities) private var identities
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate
    @Environment(\.isEnabled) private var isEnabled
    let date: Date
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    @Binding var selectedID: String?
    let create: (CalendarEventRange) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void

    private var days: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        return CalendarLayout.days(in: interval, calendar: calendar)
            .filter { !events(on: $0).isEmpty }
    }

    private func events(on day: Date) -> [CalendarDisplayEvent] {
        if let presentation, presentation.matches(calendar) { return presentation.day(day)?.events ?? [] }
        return CalendarLayout.events(events, on: day, calendar: calendar)
    }

    private var selected: CalendarDisplayEvent? { events.first { $0.id == selectedID } }

    var body: some View {
        if days.isEmpty {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "No Events This Month", systemImage: "calendar",
                               message: "Add an event or choose another month.", fillsSpace: false)
                Button("New Event") {
                    let start = CalendarLayout.date(at: 9 * 60, on: date, calendar: calendar)
                    create(CalendarEventRange(start: start, end: start.addingTimeInterval(3600), isAllDay: false))
                }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(selection: $selectedID) {
                    ForEach(days, id: \.self) { day in
                        Section {
                            ForEach(events(on: day)) { event in
                                row(event, on: day).tag(event.id)
                            }
                        } header: {
                            Text(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month(.wide).day(), calendar: calendar))
                                .font(.headline).foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : Color.primary)
                        }.id(day)
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { if isEnabled, let selected, selected.canEdit { delete(selected) } }
                .onKeyPress(.return) {
                    guard isEnabled, let selected else { return .ignored }
                    edit(selected)
                    return .handled
                }
                .onChange(of: date, initial: true) { _, _ in scrollToDate(proxy) }
                .onChange(of: days) { _, _ in scrollToDate(proxy) }
            }
        }
    }

    private func scrollToDate(_ proxy: ScrollViewProxy) {
        if let nearest = days.first(where: { $0 >= calendar.startOfDay(for: date) }) ?? days.last {
            proxy.scrollTo(nearest, anchor: .top)
        }
    }

    private func row(_ event: CalendarDisplayEvent, on day: Date) -> some View {
        let calendarTitle = identities.title(for: event.calendarKey)
        let description = eventDescription(event, calendarTitle: calendarTitle)
        return HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Text(timeLabel(event, on: day)).font(.callout).monospacedDigit()
                .frame(width: Tokens.Space.s16 + Tokens.Space.s12, alignment: .leading)
            Capsule().fill(event.color).frame(width: Tokens.Space.s1, height: Tokens.Space.s8)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(event.title).font(.headline)
                if differentiate {
                    Text(calendarTitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let location = event.event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary)
                }
                if event.isPending { Label("Pending sync", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: Tokens.Space.s2)
            if event.isRecurring { Image(systemName: "repeat").foregroundStyle(.secondary).accessibilityLabel("Repeating event") }
        }
        .padding(.vertical, Tokens.Space.s2)
        .padding(.horizontal, Tokens.Space.s2)
        .contentShape(Rectangle())
        .ternHover()
        .draggable(CalendarEventTransfer(event))
        .onTapGesture(count: 2) { if isEnabled { edit(event) } }
        .contextMenu { CalendarEventMenuItems(event: event, edit: edit, duplicate: duplicate, delete: delete) }
        .help(description)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(description)
        .accessibilityAddTraits(selectedID == event.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if isEnabled { edit(event) } }
    }

    private func eventDescription(_ event: CalendarDisplayEvent, calendarTitle: String) -> String {
        let dates = CalendarEventDateDescription.text(start: event.start, end: event.end, isAllDay: event.isAllDay, calendar: calendar)
        var parts = [event.title, calendarTitle, dates]
        if event.isAllDay { parts.append(String(localized: "All day")) }
        if let location = event.event.location, !location.isEmpty { parts.append(location) }
        if event.isPending { parts.append(String(localized: "Pending sync")) }
        if event.isRecurring { parts.append(String(localized: "Repeating event")) }
        return parts.joined(separator: ", ")
    }

    private func timeLabel(_ event: CalendarDisplayEvent, on day: Date) -> String {
        if event.isAllDay { return "All day" }
        let start = calendar.isDate(event.start, inSameDayAs: day)
            ? CalendarLayout.format(event.start, style: .dateTime.hour().minute(), calendar: calendar) : "Continues"
        let end = CalendarLayout.format(event.end, style: calendar.isDate(event.end, inSameDayAs: day)
                                       ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute(), calendar: calendar)
        return start + " – " + end
    }
}
