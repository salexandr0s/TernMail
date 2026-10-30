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
    private let hourHeight: CGFloat = 60
    private let gutter: CGFloat = 54

    private var days: [Date] {
        guard let interval = calendar.dateInterval(of: isWeek ? .weekOfYear : .day, for: date) else { return [] }
        return CalendarLayout.days(in: interval, calendar: calendar)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(calendar.timeZone.abbreviation() ?? calendar.timeZone.identifier)
                    .font(.caption2).foregroundStyle(.secondary).frame(width: gutter)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: Tokens.Space.s1) {
                        Text(CalendarLayout.format(day, style: .dateTime.weekday(.abbreviated), calendar: calendar)).font(.caption).foregroundStyle(.secondary)
                        Text("\(calendar.component(.day, from: day))").font(.title2.weight(.medium))
                            .foregroundStyle(calendar.isDateInToday(day) ? .white : .primary)
                            .frame(width: 34, height: 34).background(calendar.isDateInToday(day) ? Color.red : .clear, in: Circle())
                    }.frame(maxWidth: .infinity).padding(.vertical, Tokens.Space.s2)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.caption2).foregroundStyle(.secondary).frame(width: gutter, alignment: .trailing).padding(.top, Tokens.Space.s1)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: Tokens.Space.s0_5) {
                        ForEach(CalendarLayout.events(events, on: day, calendar: calendar).filter(\.isAllDay)) { event in
                            chip(event)
                        }
                        Color.clear.frame(height: 8).contentShape(Rectangle()).onTapGesture(count: 2) { newAllDay(day) }
                    }.padding(Tokens.Space.s1).frame(maxWidth: .infinity, minHeight: 24)
                        .dropDestination(for: String.self) { values, _ in
                            guard let id = values.first, let event = events.first(where: { $0.id == id }), event.canEdit, event.isAllDay else { return false }
                            move(event, calendar.startOfDay(for: day)); return true
                        }
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in
                                Text(CalendarLayout.date(at: hour * 60, on: date, calendar: calendar), format: .dateTime.hour())
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: gutter - 8, height: hourHeight, alignment: .topTrailing)
                                    .padding(.trailing, 8).id(hour)
                            }
                        }
                        ForEach(days, id: \.self) { day in
                            dayColumn(day).frame(maxWidth: .infinity)
                        }
                    }.padding(.top, Tokens.Space.s2)
                }
                .onAppear { proxy.scrollTo(8, anchor: .top) }
            }
        }
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
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { newEvent(CalendarLayout.date(at: hour * 60, on: day, calendar: calendar)) }
                            .onTapGesture { selectedID = nil }
                    }
                }
                ForEach(placements) { placement in
                    let width = max(20, (geometry.size.width - 6) / CGFloat(placement.lanes))
                    CalendarTimelineEvent(event: placement.event, selected: selectedID == placement.event.id,
                                          height: max(22, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight),
                                          hourHeight: hourHeight,
                                          select: { selectedID = placement.event.id }, edit: { edit(placement.event) },
                                          resize: { minutes in
                                              let end = calendar.date(byAdding: .minute, value: minutes, to: placement.event.end) ?? placement.event.end
                                              if end > placement.event.start { resize(placement.event, end) }
                                          })
                        .frame(width: width - 2)
                        .offset(x: CGFloat(placement.lane) * width + 2, y: CGFloat(placement.startMinute) / 60 * hourHeight)
                        .contextMenu {
                            Button("Open event") { edit(placement.event) }
                            Button("Duplicate") { duplicate(placement.event) }
                            Button("Delete", role: .destructive) { delete(placement.event) }.disabled(!placement.event.canEdit)
                        }
                }
                if calendar.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let parts = calendar.dateComponents([.hour, .minute], from: context.date)
                        Rectangle().fill(.red).frame(height: 1)
                            .overlay(alignment: .leading) { Circle().fill(.red).frame(width: 5, height: 5) }
                            .offset(y: CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 60 * hourHeight)
                    }.allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) { Divider() }
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
            .accessibilityAction { edit() }
            .accessibilityAction(named: "Extend by 15 minutes") { if event.canEdit { resize(15) } }
            .accessibilityAction(named: "Shorten by 15 minutes") { if event.canEdit { resize(-15) } }
            .help(event.title + "\n" + event.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone)))
    }

    private var eventContent: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            Text(event.title).font(.caption.weight(.semibold)).lineLimit(height > 50 ? 2 : 1)
            if height > 35 {
                Text(event.start, style: .time).font(.caption2)
                if height > 70, let location = event.event.location { Text(location).font(.caption2).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.s1)
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: max(22, height + resizeOffset))
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? event.color : event.color.opacity(0.20), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3) }
    }

    @ViewBuilder private var resizeHandle: some View {
        if event.canEdit, selected {
            Capsule().fill(event.color).frame(width: 24, height: 4).padding(.bottom, 2)
                .contentShape(Rectangle().inset(by: -5))
                .gesture(DragGesture(minimumDistance: 3)
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
