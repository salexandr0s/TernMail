import SwiftUI

struct CalendarGridViews: View {
    @Binding var mode: CalendarDisplayMode
    @Binding var date: Date
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    @Binding var selectedID: String?
    let newEvent: (Date) -> Void
    let newAllDay: (Date) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    let move: (CalendarDisplayEvent, Date) -> Void
    let resize: (CalendarDisplayEvent, Date) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void

    var body: some View {
        switch mode {
        case .day, .week:
            CalendarTimeGrid(date: date, isWeek: mode == .week, calendar: calendar, events: events,
                             selectedID: $selectedID, newEvent: newEvent, newAllDay: newAllDay, edit: edit, move: move,
                             resize: resize, delete: delete, duplicate: duplicate)
        case .month:
            month
        case .year:
            year
        }
    }

    private var month: some View {
        GeometryReader { geometry in
            let days = CalendarLayout.monthDays(containing: date, calendar: calendar)
            VStack(spacing: 0) {
                CalendarWeekdayHeader(calendar: calendar)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        monthCell(day, height: max(80, (geometry.size.height - 26) / 6))
                    }
                }
            }
        }
    }

    private func monthCell(_ day: Date, height: CGFloat) -> some View {
        let dayEvents = CalendarLayout.events(events, on: day, calendar: calendar)
        let rowLimit = max(1, Int((height - 32) / 22))
        return VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            HStack {
                Spacer()
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.weight(calendar.isDateInToday(day) ? .bold : .regular))
                    .foregroundStyle(calendar.isDateInToday(day) ? .white : .primary)
                    .frame(width: 25, height: 25)
                    .background(calendar.isDateInToday(day) ? Color.red : .clear, in: Circle())
            }
            ForEach(dayEvents.prefix(rowLimit)) { event in
                CalendarEventChip(event: event, selected: selectedID == event.id, showsTime: !event.isAllDay)
                    .onTapGesture(count: 2) { edit(event) }
                    .onTapGesture { selectedID = event.id }
                    .draggable(event.canEdit ? event.id : "")
                    .contextMenu { eventMenu(event) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { edit(event) }
                    .accessibilityAction(named: "Duplicate") { duplicate(event) }
            }
            if dayEvents.count > rowLimit {
                Button("\(dayEvents.count - rowLimit) more") { date = day; mode = .day }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.s1)
        .frame(maxWidth: .infinity).frame(height: height)
        .background(calendar.isDate(day, equalTo: date, toGranularity: .month) ? Tokens.Surface.primary : Tokens.Surface.muted)
        .overlay(alignment: .bottom) { Divider() }
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { newEvent(CalendarLayout.date(at: 9 * 60, on: day, calendar: calendar)) }
        .onTapGesture { selectedID = nil }
        .dropDestination(for: String.self) { values, _ in
            guard let id = values.first, let event = events.first(where: { $0.id == id }), event.canEdit else { return false }
            let time = calendar.dateComponents([.hour, .minute], from: event.start)
            move(event, CalendarLayout.date(at: (time.hour ?? 0) * 60 + (time.minute ?? 0), on: day, calendar: calendar))
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month().day(), calendar: calendar))
    }

    private var year: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: Tokens.Space.s8)], spacing: Tokens.Space.s8) {
                ForEach(1...12, id: \.self) { month in
                    if let monthDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: date), month: month, day: 1)) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Text(CalendarLayout.format(monthDate, style: .dateTime.month(.wide), calendar: calendar)).font(.title3.weight(.semibold)).foregroundStyle(.red)
                            CalendarMiniMonth(date: $date, calendar: calendar, fixedMonth: monthDate, events: events) { chosen in
                                date = chosen; mode = .day
                            }
                        }
                    }
                }
            }.padding(Tokens.Space.s6)
        }
    }

    @ViewBuilder private func eventMenu(_ event: CalendarDisplayEvent) -> some View {
        Button("Open event") { edit(event) }
        Button("Duplicate") { duplicate(event) }
        Button("Delete", role: .destructive) { delete(event) }.disabled(!event.canEdit)
    }
}

struct CalendarEventChip: View {
    @Environment(\.timeZone) private var timeZone
    let event: CalendarDisplayEvent
    var selected = false
    var showsTime = true

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            if !event.isAllDay { RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3, height: 14) }
            if showsTime { Text(event.start, style: .time).font(.caption2).lineLimit(1) }
            Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
            if event.isPending { Image(systemName: "clock.arrow.circlepath").font(.caption2) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Space.s1).padding(.vertical, Tokens.Space.s0_5)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? event.color : event.color.opacity(event.isAllDay ? 0.22 : 0.09), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .contentShape(Rectangle())
        .help(event.title + "\n" + dateDescription)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(event.title + ", " + dateDescription)
    }

    private var dateDescription: String {
        event.start.formatted(Date.FormatStyle(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened, timeZone: timeZone))
    }
}

struct CalendarWeekdayHeader: View {
    let calendar: Calendar
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<7) { offset in
                Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7])
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }.frame(height: 26)
    }
}

struct CalendarMiniMonth: View {
    @Binding var date: Date
    let calendar: Calendar
    var fixedMonth: Date?
    var events: [CalendarDisplayEvent] = []
    var select: ((Date) -> Void)?

    var body: some View {
        let month = fixedMonth ?? date
        VStack(spacing: Tokens.Space.s1) {
            if fixedMonth == nil {
                HStack {
                    Text(CalendarLayout.format(month, style: .dateTime.month(.wide).year(), calendar: calendar)).font(.caption.weight(.semibold))
                    Spacer()
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous month")
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next month")
                }.buttonStyle(.borderless)
            }
            CalendarWeekdayHeader(calendar: calendar)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: Tokens.Space.s1) {
                ForEach(CalendarLayout.monthDays(containing: month, calendar: calendar), id: \.self) { day in
                    Button {
                        if let select { select(day) } else { date = day }
                    } label: {
                        VStack(spacing: 1) {
                            Text("\(calendar.component(.day, from: day))")
                                .font(.caption).frame(width: 23, height: 23)
                                .foregroundStyle(calendar.isDateInToday(day) ? .white : .primary)
                                .background(calendar.isDateInToday(day) ? Color.red : calendar.isDate(day, inSameDayAs: date) ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                            Circle().fill(CalendarLayout.events(events, on: day, calendar: calendar).isEmpty ? Color.clear : .secondary).frame(width: 3, height: 3)
                        }
                        .opacity(calendar.isDate(day, equalTo: month, toGranularity: .month) ? 1 : 0.3)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month().day().year(), calendar: calendar))
                }
            }
        }
    }
    private func shift(_ amount: Int) { date = calendar.date(byAdding: .month, value: amount, to: date) ?? date }
}

struct CalendarSearchResults: View {
    let events: [CalendarDisplayEvent]
    let calendar: Calendar
    @Binding var selectedID: String?
    let edit: (CalendarDisplayEvent) -> Void
    var body: some View {
        if events.isEmpty {
            TernEmptyState(title: "No matching events", systemImage: "magnifyingglass", message: "Try another title or location, or choose a different date window.")
        } else {
            List(events, selection: $selectedID) { event in
                HStack(spacing: Tokens.Space.s3) {
                    RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 4)
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(event.title).font(.headline)
                        Text(CalendarLayout.format(event.start, style: .init(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened), calendar: calendar)).font(.caption).foregroundStyle(.secondary)
                        if let location = event.event.location, !location.isEmpty { Text(location).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }.padding(.vertical, Tokens.Space.s1).tag(event.id).onTapGesture(count: 2) { edit(event) }
            }
        }
    }
}
