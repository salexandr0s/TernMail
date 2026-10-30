import SwiftUI

struct CalendarTimeGrid: View {
    let date: Date
    let isWeek: Bool
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
    private let hourHeight = Tokens.Space.s16
    private let gutter = Tokens.Space.s16

    private var days: [Date] {
        guard let interval = calendar.dateInterval(of: isWeek ? .weekOfYear : .day, for: date) else { return [] }
        return CalendarLayout.days(in: interval, calendar: calendar)
    }

    var body: some View {
        GeometryReader { geometry in
            let minimumWidth = gutter + CGFloat(days.count) * (Tokens.Space.s16 + Tokens.Space.s8)
            let contentWidth = max(geometry.size.width, minimumWidth)
            let columnWidth = (contentWidth - gutter) / CGFloat(max(1, days.count))
            ScrollView(.horizontal) {
                timeline(columnWidth: columnWidth)
                    .frame(width: contentWidth, height: geometry.size.height)
            }
        }
    }

    private func timeline(columnWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            dayHeaders(columnWidth: columnWidth)
            Divider()
            allDayLane(columnWidth: columnWidth)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in
                                Text(CalendarLayout.date(at: hour * 60, on: date, calendar: calendar), format: .dateTime.hour())
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: gutter - Tokens.Space.s2, height: hourHeight, alignment: .topTrailing)
                                    .padding(.trailing, Tokens.Space.s2).id(hour)
                            }
                        }
                        ForEach(days, id: \.self) { day in
                            dayColumn(day).frame(width: columnWidth)
                        }
                    }.padding(.top, Tokens.Space.s2)
                }
                .onAppear { proxy.scrollTo(8, anchor: .top) }
            }
        }
    }

    private func dayHeaders(columnWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(calendar.timeZone.abbreviation(for: date) ?? calendar.timeZone.identifier)
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary).frame(width: gutter)
                .help(calendar.timeZone.identifier)
            ForEach(days, id: \.self) { day in
                VStack(spacing: Tokens.Space.s1) {
                    Text(CalendarLayout.format(day, style: .dateTime.weekday(.abbreviated), calendar: calendar))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text("\(calendar.component(.day, from: day))")
                        .font(.title2.weight(calendar.isDateInToday(day) ? .semibold : .regular)).monospacedDigit()
                        .frame(width: Tokens.Space.s10, height: Tokens.Space.s10)
                        .background(calendar.isDateInToday(day) ? Color.accentColor.opacity(Tokens.Calendar.selectedTint) : .clear, in: Circle())
                }
                .frame(width: columnWidth).padding(.vertical, Tokens.Space.s2)
                .background(calendar.isDateInWeekend(day) ? Tokens.Surface.muted : Tokens.Surface.primary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month(.wide).day(), calendar: calendar))
                .accessibilityValue(calendar.isDateInToday(day) ? "Today" : "")
            }
        }
    }

    private func allDayLane(columnWidth: CGFloat) -> some View {
        let rowCount = days.map { CalendarLayout.events(events, on: $0, calendar: calendar).filter(\.isAllDay).count }.max() ?? 0
        let height = max(Tokens.Space.s8, min(CGFloat(rowCount), 3) * (Tokens.Space.s6 + Tokens.Space.s0_5) + Tokens.Space.s4)
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                Text("All day").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: gutter - Tokens.Space.s2, alignment: .trailing)
                    .padding(.trailing, Tokens.Space.s2).padding(.top, Tokens.Space.s2)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: Tokens.Space.s0_5) {
                        ForEach(CalendarLayout.events(events, on: day, calendar: calendar).filter(\.isAllDay)) { event in
                            chip(event)
                        }
                        Color.clear.frame(height: Tokens.Space.s2)
                    }
                    .padding(Tokens.Space.s1).frame(width: columnWidth).frame(minHeight: Tokens.Space.s8)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { newAllDay(day) }
                    .dropDestination(for: String.self) { values, _ in
                        guard let id = values.first, let event = events.first(where: { $0.id == id }), event.canEdit, event.isAllDay else { return false }
                        move(event, calendar.startOfDay(for: day)); return true
                    }
                }
            }
        }
        .frame(height: height)
        .background(Tokens.Surface.muted)
    }

    private func dayColumn(_ day: Date) -> some View {
        GeometryReader { geometry in
            let timed = CalendarLayout.events(events, on: day, calendar: calendar).filter { !$0.isAllDay }
            let placements = CalendarTimelinePlacement.layout(timed, day: day, calendar: calendar)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24) { hour in
                        Rectangle().fill(Color.clear).frame(height: hourHeight)
                            .overlay(alignment: .top) { Divider() }
                            .overlay { Rectangle().fill(Tokens.Surface.border).frame(height: Tokens.Border.hairline).opacity(Tokens.Calendar.selectedTint) }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { newEvent(CalendarLayout.date(at: hour * 60, on: day, calendar: calendar)) }
                            .onTapGesture { selectedID = nil }
                    }
                }
                ForEach(placements) { placement in
                    let width = max(Tokens.Space.s1, (geometry.size.width - Tokens.Space.s1_5) / CGFloat(placement.lanes))
                    CalendarTimelineEvent(event: placement.event, selected: selectedID == placement.event.id,
                                          height: max(Tokens.Space.s6, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight),
                                          hourHeight: hourHeight,
                                          select: { selectedID = placement.event.id }, edit: { edit(placement.event) },
                                          resize: { minutes in
                                              let end = calendar.date(byAdding: .minute, value: minutes, to: placement.event.end) ?? placement.event.end
                                              if end > placement.event.start { resize(placement.event, end) }
                                          })
                        .frame(width: width - Tokens.Space.s0_5)
                        .offset(x: CGFloat(placement.lane) * width + Tokens.Space.s0_5, y: CGFloat(placement.startMinute) / 60 * hourHeight)
                        .contextMenu {
                            Button("Open event") { edit(placement.event) }
                            Button("Duplicate") { duplicate(placement.event) }
                            Button("Delete", role: .destructive) { delete(placement.event) }.disabled(!placement.event.canEdit)
                        }
                }
                if calendar.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let parts = calendar.dateComponents([.hour, .minute], from: context.date)
                        Rectangle().fill(Color.accentColor).frame(height: Tokens.Border.focus)
                            .overlay(alignment: .leading) { Circle().fill(Color.accentColor).frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5) }
                            .offset(y: CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 60 * hourHeight)
                    }.allowsHitTesting(false)
                }
            }
            .background { if calendar.isDateInToday(day) { Color.accentColor.opacity(Tokens.Calendar.todayTint) } }
            .background(calendar.isDateInWeekend(day) ? Tokens.Surface.muted : Tokens.Surface.primary)
            .clipped()
            .overlay(alignment: .trailing) {
                Rectangle().fill(Tokens.Surface.border).frame(width: Tokens.Border.hairline).allowsHitTesting(false)
            }
            .dropDestination(for: String.self) { values, location in
                guard let id = values.first, let event = events.first(where: { $0.id == id }), event.canEdit else { return false }
                let minutes = max(0, min(23 * 60 + 45, Int((location.y / hourHeight * 60) / 15) * 15))
                move(event, CalendarLayout.date(at: minutes, on: day, calendar: calendar))
                return true
            }
        }.frame(height: hourHeight * 24)
    }

    private func chip(_ event: CalendarDisplayEvent) -> some View {
        CalendarEventChip(event: event, selected: selectedID == event.id, showsTime: false)
            .onTapGesture(count: 2) { edit(event) }.onTapGesture { selectedID = event.id }
            .draggable(event.canEdit ? event.id : "")
            .accessibilityAddTraits(.isButton).accessibilityAction { edit(event) }
            .contextMenu {
                Button("Open event") { edit(event) }
                Button("Duplicate") { duplicate(event) }
                Button("Delete", role: .destructive) { delete(event) }.disabled(!event.canEdit)
            }
    }
}

private struct CalendarTimelineEvent: View {
    @Environment(\.timeZone) private var timeZone
    let event: CalendarDisplayEvent
    let selected: Bool
    let height: CGFloat
    let hourHeight: CGFloat
    let select: () -> Void
    let edit: () -> Void
    let resize: (Int) -> Void
    @State private var resizeOffset: CGFloat = 0

    var body: some View {
        eventContent
            .overlay(alignment: .bottom) { resizeHandle }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: edit).onTapGesture(perform: select)
            .draggable(event.canEdit ? event.id : "")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(event.title + ", " + timeDescription)
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityAction { edit() }
            .accessibilityAction(named: "Extend by 15 minutes") { if event.canEdit { resize(15) } }
            .accessibilityAction(named: "Shorten by 15 minutes") { if event.canEdit { resize(-15) } }
            .help(event.title + "\n" + timeDescription)
    }

    private var eventContent: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            HStack(alignment: .top, spacing: Tokens.Space.s1) {
                Text(event.title).font(.caption.weight(.semibold)).lineLimit(height >= Tokens.Space.s16 ? 2 : 1)
                if event.isPending { Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(.secondary) }
            }
            if height >= Tokens.Space.s12 {
                Text(event.start, style: .time).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                if height > Tokens.Space.s16 + Tokens.Space.s4, let location = event.event.location, !location.isEmpty {
                    Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Space.s1).padding(.horizontal, Tokens.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: max(Tokens.Space.s6, height + resizeOffset))
        .foregroundStyle(Color.primary)
        .background(event.color.opacity(selected ? Tokens.Calendar.selectedTint : Tokens.Calendar.allDayTint), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay(alignment: .leading) { Capsule().fill(event.color).frame(width: Tokens.Space.s0_5).padding(.vertical, Tokens.Space.s1) }
        .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: Tokens.Border.focus) }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    private var timeDescription: String {
        event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))
            + " – " + event.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
            + (event.isPending ? ", pending sync" : "")
    }

    @ViewBuilder private var resizeHandle: some View {
        if event.canEdit, selected {
            Capsule().fill(Color.accentColor).frame(width: Tokens.Space.s6, height: Tokens.Space.s1).padding(.bottom, Tokens.Space.s0_5)
                .contentShape(Rectangle().inset(by: -Tokens.Space.s1_5))
                .gesture(DragGesture(minimumDistance: Tokens.Space.s1)
                    .onChanged { resizeOffset = $0.translation.height }
                    .onEnded { value in
                        resizeOffset = 0
                        let minutes = Int((value.translation.height / hourHeight * 60 / 15).rounded()) * 15
                        if minutes != 0 { resize(minutes) }
                    })
                .accessibilityLabel("Resize event duration")
        }
    }
}

struct CalendarTimelinePlacement: Identifiable {
    var event: CalendarDisplayEvent
    var startMinute: Int
    var endMinute: Int
    var lane: Int
    var lanes: Int
    var id: String { event.id }

    static func layout(_ events: [CalendarDisplayEvent], day: Date, calendar: Calendar) -> [Self] {
        guard let bounds = calendar.dateInterval(of: .day, for: day) else { return [] }
        var result: [Self] = []
        var group: [Self] = []
        var laneEnds: [Int] = []
        var groupEnd = 0
        func flush() {
            result += group.map { value in var copy = value; copy.lanes = laneEnds.count; return copy }
            group = []; laneEnds = []; groupEnd = 0
        }
        for event in events.sorted(by: { $0.start < $1.start }) {
            let startParts = calendar.dateComponents([.hour, .minute], from: event.start)
            let endParts = calendar.dateComponents([.hour, .minute], from: event.end)
            let start = event.start <= bounds.start ? 0 : (startParts.hour ?? 0) * 60 + (startParts.minute ?? 0)
            let end = event.end >= bounds.end ? 1440 : max(start + 15, (endParts.hour ?? 0) * 60 + (endParts.minute ?? 0))
            if start >= groupEnd, !group.isEmpty { flush() }
            let lane = laneEnds.firstIndex(where: { $0 <= start }) ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
            group.append(Self(event: event, startMinute: start, endMinute: end, lane: lane, lanes: 1))
            groupEnd = max(groupEnd, end)
        }
        flush()
        return result
    }
}
