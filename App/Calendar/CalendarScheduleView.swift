import SwiftUI

struct CalendarScheduleView: View {
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
            .filter { !CalendarLayout.events(events, on: $0, calendar: calendar).isEmpty }
    }

    var body: some View {
        if days.isEmpty {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "No events this month", systemImage: "calendar",
                               message: "Add an event or choose another month.", fillsSpace: false)
                Button("New event") {
                    let start = CalendarLayout.date(at: 9 * 60, on: date, calendar: calendar)
                    create(CalendarEventRange(start: start, end: start.addingTimeInterval(3600), isAllDay: false))
                }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(days, id: \.self) { day in
                        Section {
                            ForEach(CalendarLayout.events(events, on: day, calendar: calendar)) { event in
                                row(event, on: day)
                            }
                        } header: {
                            Text(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month(.wide).day(), calendar: calendar))
                                .font(.headline).foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : Color.primary)
                        }.id(day)
                    }
                }.listStyle(.inset)
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
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Text(timeLabel(event, on: day)).font(.callout).monospacedDigit()
                .frame(width: Tokens.Space.s16 + Tokens.Space.s12, alignment: .leading)
            Capsule().fill(event.color).frame(width: Tokens.Space.s1, height: Tokens.Space.s8)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(event.title).font(.headline)
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
        .background(selectedID == event.id ? Color.accentColor.opacity(Tokens.Calendar.selectedTint) : .clear,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit(event) }.onTapGesture { selectedID = event.id }
        .contextMenu {
            Button("Open event") { edit(event) }
            Button("Duplicate") { duplicate(event) }
            Button("Delete", role: .destructive) { delete(event) }.disabled(!event.canEdit)
        }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
        .accessibilityAction { edit(event) }
        .accessibilityValue(selectedID == event.id ? "Selected" : "")
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
