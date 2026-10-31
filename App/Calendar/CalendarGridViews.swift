import MessageContent
import SwiftUI

struct CalendarGridViews: View {
    @Binding var mode: CalendarDisplayMode
    @Binding var date: Date
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    @Binding var selectedID: String?
    let create: (CalendarEventRange) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    let change: (CalendarDisplayEvent, CalendarEventRange) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    /// A conversation dropped on the grid, with the slot it landed on.
    let dropMail: (MailLink, CalendarEventRange) -> Void

    var body: some View {
        switch mode {
        case .day, .week:
            CalendarTimeGrid(date: date, isWeek: mode == .week, calendar: calendar, events: events,
                             selectedID: $selectedID, create: create, edit: edit, change: change,
                             delete: delete, duplicate: duplicate, dropMail: dropMail)
        case .month:
            CalendarMonthGrid(date: $date, calendar: calendar, events: events, selectedID: $selectedID,
                              create: create, edit: edit, change: change, delete: delete, duplicate: duplicate,
                              dropMail: dropMail, openDay: { date = $0; mode = .day })
        case .schedule:
            CalendarScheduleView(date: date, calendar: calendar, events: events, selectedID: $selectedID,
                                 create: create, edit: edit, delete: delete, duplicate: duplicate)
        case .year:
            year
        }
    }

    private var year: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Layout.attachmentWidth), spacing: Tokens.Space.s4)], spacing: Tokens.Space.s4) {
                ForEach(1...12, id: \.self) { month in
                    if let monthDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: date), month: month, day: 1)) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Button {
                                date = monthDate; mode = .month
                            } label: {
                                HStack {
                                    Text(CalendarLayout.format(monthDate, style: .dateTime.month(.wide), calendar: calendar))
                                        .font(.title3.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Show " + CalendarLayout.format(monthDate, style: .dateTime.month(.wide).year(), calendar: calendar))
                            CalendarMiniMonth(date: $date, calendar: calendar, fixedMonth: monthDate, events: events) { chosen in
                                date = chosen; mode = .day
                            }
                        }
                        .padding(Tokens.Space.s4)
                        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                        .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
                    }
                }
            }.padding(Tokens.Space.s4)
        }.background(Tokens.Surface.canvas)
    }
}

struct CalendarEventChip: View {
    @Environment(\.timeZone) private var timeZone
    @Environment(\.colorSchemeContrast) private var contrast
    let event: CalendarDisplayEvent
    var selected = false
    var showsTime = true
    /// The grab pointer while the chip can be moved; nil keeps the arrow.
    var pointer: PointerStyle?

    var body: some View {
        content
            .padding(.horizontal, Tokens.Space.s1_5)
            .frame(height: Tokens.Space.s6)
            .foregroundStyle(Color.primary)
            .background(event.color.opacity(CalendarColor.tint(tint, contrast: contrast)), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(outlineColor, lineWidth: Tokens.Border.focus) }
            .contentShape(Rectangle())
            .ternHover(pointer: pointer)
            .help(event.title + "\n" + dateDescription)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(event.title + ", " + dateDescription)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var content: some View {
        HStack(spacing: Tokens.Space.s1) {
            Capsule().fill(event.color).frame(width: Tokens.Space.s0_5, height: Tokens.Space.s3)
            Text(event.title).font(.caption.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            if showsTime {
                Text(event.start, style: .time).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if event.isPending { Image(systemName: "clock.arrow.circlepath").font(.caption2) }
        }
    }

    private var tint: Double {
        if selected { return Tokens.Calendar.selectedTint }
        return event.isAllDay ? Tokens.Calendar.allDayTint : Tokens.Calendar.eventTint
    }

    private var outlineColor: Color { selected ? .accentColor : .clear }

    private var dateDescription: String {
        event.start.formatted(Date.FormatStyle(date: .abbreviated, time: event.isAllDay ? .omitted : .shortened, timeZone: timeZone))
            + (event.isAllDay ? ", all day" : " – " + event.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)))
            + (event.isPending ? ", pending sync" : "")
    }
}

struct CalendarWeekdayHeader: View {
    let calendar: Calendar
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(0..<7) { offset in
                    Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7])
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(width: geometry.size.width / 7, height: Tokens.Space.s8)
                }
            }
        }.frame(height: Tokens.Space.s8)
    }
}

struct CalendarMiniMonth: View {
    @Binding var date: Date
    let calendar: Calendar
    var fixedMonth: Date?
    var events: [CalendarDisplayEvent] = []
    var select: ((Date) -> Void)?

    private static let cellHeight = Tokens.Space.s6 + Tokens.Space.s0_5 + Tokens.Space.s1
    private static let gridHeight = Tokens.Space.s8 + 6 * (cellHeight + Tokens.Space.s1)
    /// The month with its title row, for callers that size a container to it.
    static let height = Tokens.Space.s6 + Tokens.Space.s1 + gridHeight

    var body: some View {
        let month = fixedMonth ?? date
        VStack(spacing: Tokens.Space.s1) {
            if fixedMonth == nil {
                HStack {
                    Text(CalendarLayout.format(month, style: .dateTime.month(.wide).year(), calendar: calendar)).font(.callout.weight(.semibold))
                    Spacer()
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous month")
                        .help("Previous month")
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next month")
                        .help("Next month")
                }.buttonStyle(.borderless).frame(height: Tokens.Space.s6)
            }
            dateGrid(month: month)
        }
    }

    private func dateGrid(month: Date) -> some View {
        let days = CalendarLayout.monthDays(containing: month, calendar: calendar)
        return GeometryReader { geometry in
            let columnWidth = geometry.size.width / 7
            VStack(spacing: Tokens.Space.s1) {
                CalendarWeekdayHeader(calendar: calendar)
                VStack(spacing: Tokens.Space.s1) {
                    ForEach(0..<6) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7) { column in
                                let index = row * 7 + column
                                if index < days.count {
                                    dayButton(days[index], month: month)
                                        .frame(width: columnWidth, height: Self.cellHeight)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: Self.gridHeight)
    }

    private func dayButton(_ day: Date, month: Date) -> some View {
        Button {
            if let select { select(day) } else { date = day }
        } label: {
            VStack(spacing: Tokens.Space.s0_5) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.weight(calendar.isDateInToday(day) ? .bold : .regular)).monospacedDigit()
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .foregroundStyle(calendar.isDate(day, equalTo: month, toGranularity: .month) ? Color.primary : Color.secondary)
                    .background(calendar.isDateInToday(day) ? Color.accentColor.opacity(Tokens.Calendar.selectedTint) : .clear, in: Circle())
                    .overlay { Circle().strokeBorder(calendar.isDate(day, inSameDayAs: date) ? Color.accentColor : .clear, lineWidth: Tokens.Border.focus) }
                Circle().fill(CalendarLayout.events(events, on: day, calendar: calendar).isEmpty ? Color.clear : .secondary)
                    .frame(width: Tokens.Space.s1, height: Tokens.Space.s1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .ternHover()
            .accessibilityLabel(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month().day().year(), calendar: calendar))
            .accessibilityValue(calendar.isDate(day, inSameDayAs: date) ? "Selected" : calendar.isDateInToday(day) ? "Today" : "")
    }

    private func shift(_ amount: Int) { date = calendar.date(byAdding: .month, value: amount, to: date) ?? date }
}

struct CalendarSearchResults: View {
    let events: [CalendarDisplayEvent]
    let calendar: Calendar
    @Binding var selectedID: String?
    let edit: (CalendarDisplayEvent) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    var body: some View {
        if events.isEmpty {
            TernEmptyState(title: "No matching events", systemImage: "magnifyingglass", message: "Try another title or location, or choose a different date window.")
        } else {
            List(events, selection: $selectedID) { event in
                HStack(spacing: Tokens.Space.s3) {
                    VStack(spacing: Tokens.Space.s0_5) {
                        Text(CalendarLayout.format(event.start, style: .dateTime.month(.abbreviated), calendar: calendar))
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text("\(calendar.component(.day, from: event.start))")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                    }
                    .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                    .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    Capsule().fill(event.color).frame(width: Tokens.Space.s1, height: Tokens.Space.s10)
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        HStack(spacing: Tokens.Space.s2) {
                            Text(event.title).font(.headline).lineLimit(1)
                            if event.isPending { Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary).help("Pending sync") }
                        }
                        Text(CalendarLayout.format(event.start, style: .dateTime.weekday(.wide).month(.abbreviated).day().year(), calendar: calendar))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let location = event.event.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: Tokens.Space.s2)
                    VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                        if event.isAllDay {
                            Text("All day").font(.callout.weight(.medium))
                        } else {
                            Text(CalendarLayout.format(event.start, style: .dateTime.hour().minute(), calendar: calendar))
                                .font(.callout.weight(.medium)).monospacedDigit()
                            Text(CalendarLayout.format(event.end, style: .dateTime.hour().minute(), calendar: calendar))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.fixedSize()
                }
                .padding(.vertical, Tokens.Space.s2).tag(event.id)
                .contentShape(Rectangle())
                .ternHover()
                .draggable(CalendarEventTransfer(event))
                .onTapGesture(count: 2) { edit(event) }
                .help(event.title)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selectedID == event.id ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { edit(event) }
                .contextMenu {
                    Button("Open Event") { edit(event) }
                    Button("Duplicate") { duplicate(event) }
                    Button("Delete", role: .destructive) { delete(event) }.disabled(!event.canEdit)
                }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                if let event = events.first(where: { $0.id == selectedID }), event.canEdit { delete(event) }
            }
            .onKeyPress(.return) {
                guard let event = events.first(where: { $0.id == selectedID }) else { return .ignored }
                edit(event)
                return .handled
            }
        }
    }
}
