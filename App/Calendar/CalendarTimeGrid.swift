import SwiftUI

struct CalendarTimeGrid: View {
    let date: Date
    let isWeek: Bool
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    @Binding var selectedID: String?
    let create: (CalendarEventRange) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    let change: (CalendarDisplayEvent, CalendarEventRange) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    let hourHeight = Tokens.Space.s16
    let gutter = Tokens.Space.s16
    static let coordinateSpace = "calendarTimeline"
    @State var frames: [CalendarTimelineRegion: CGRect] = [:]
    @State var drag: CalendarTimelineDrag?
    @State var dragCancelled = false
    @GestureState var pointerIsDown = false

    var days: [Date] {
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
            .calendarTimelineFrame(.canvas)
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(CalendarTimelineFrames.self) { value in
            frames = value
            if let drag, !dragCancelled { updateDrag(at: drag.pointer) }
        }
        .background(CalendarDragCancellation(isActive: drag != nil) { cancelDrag() })
        .onChange(of: pointerIsDown) { _, isDown in
            if !isDown { drag = nil; dragCancelled = false }
        }
        .onChange(of: events) { _, current in
            if let source = drag?.action.event, current.first(where: { $0.id == source.id }) != source { cancelDrag() }
        }
        .onChange(of: date) { _, _ in cancelDrag() }
        .onChange(of: isWeek) { _, _ in cancelDrag() }
        .onChange(of: calendar.timeZone.identifier) { _, _ in cancelDrag() }
        .onChange(of: calendar.firstWeekday) { _, _ in cancelDrag() }
        .onDisappear { drag = nil; dragCancelled = false }
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
                                Text(CalendarLayout.format(CalendarInteraction.date(at: hour * 60, on: date, calendar: calendar),
                                                           style: .dateTime.hour(), calendar: calendar))
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: gutter - Tokens.Space.s2, height: hourHeight, alignment: .topTrailing)
                                    .padding(.trailing, Tokens.Space.s2).id(hour)
                            }
                        }
                        ForEach(days, id: \.self) { day in dayColumn(day, width: columnWidth) }
                    }
                    .calendarTimelineFrame(.content)
                    .background(CalendarDragAutoScroll(direction: scrollDirection))
                    .padding(.top, Tokens.Space.s2)
                }
                .calendarTimelineFrame(.viewport)
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
        let rowHeight = Tokens.Space.s6 + Tokens.Space.s0_5
        let contentHeight = max(Tokens.Space.s8, CGFloat(rowCount + 1) * rowHeight + Tokens.Space.s2)
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                Text("All day").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: gutter - Tokens.Space.s2, alignment: .trailing)
                    .padding(.trailing, Tokens.Space.s2).padding(.top, Tokens.Space.s2)
                ForEach(days, id: \.self) { day in
                    ZStack(alignment: .top) {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .gesture(pointerGesture(.createAllDay).exclusively(before: TapGesture().onEnded {
                                create(CalendarInteraction.selection(from: day, to: day, allDay: true, calendar: calendar))
                            }))
                            .help("Click or drag to create an all-day event")
                        VStack(spacing: Tokens.Space.s0_5) {
                            ForEach(CalendarLayout.events(events, on: day, calendar: calendar).filter(\.isAllDay)) { event in
                                allDayChip(event, day: day)
                            }
                            if let preview = previewEvent, preview.isAllDay,
                               !CalendarLayout.events([preview], on: day, calendar: calendar).isEmpty {
                                CalendarEventChip(event: preview, selected: true, showsTime: false).allowsHitTesting(false)
                            }
                            Spacer(minLength: Tokens.Space.s2)
                        }.padding(Tokens.Space.s1).allowsHitTesting(true)
                    }
                    .frame(width: columnWidth, height: contentHeight)
                }
            }
        }
        .frame(height: min(contentHeight, 4 * rowHeight + Tokens.Space.s2))
        .calendarTimelineFrame(.allDay)
        .background(Tokens.Surface.muted)
    }

    private func allDayChip(_ event: CalendarDisplayEvent, day: Date) -> some View {
        CalendarEventChip(event: event, selected: selectedID == event.id, showsTime: false)
            .onTapGesture(count: 2) { edit(event) }.onTapGesture { selectedID = event.id }
            .gesture(pointerGesture(.move(event, day)), including: event.canEdit ? .all : .subviews)
            .overlay(alignment: .leading) {
                if selectedID == event.id, event.canEdit, calendar.isDate(day, inSameDayAs: event.start) {
                    allDayHandle(.resizeStart(event))
                }
            }
            .overlay(alignment: .trailing) {
                if selectedID == event.id, event.canEdit, calendar.isDate(day, inSameDayAs: event.end.addingTimeInterval(-1)) {
                    allDayHandle(.resizeEnd(event))
                }
            }
            .opacity(drag?.action.event?.id == event.id ? Tokens.Calendar.selectedTint : 1)
            .accessibilityAddTraits(.isButton).accessibilityAction { edit(event) }
            .contextMenu { eventMenu(event) }
    }

    private func allDayHandle(_ action: CalendarTimelineAction) -> some View {
        Capsule().fill(Color.accentColor).frame(width: Tokens.Space.s1, height: Tokens.Space.s3)
            .frame(width: Tokens.Space.s2, height: Tokens.Space.s6).contentShape(Rectangle())
            .highPriorityGesture(pointerGesture(action))
            .help(action.isStartEdge ? "Drag to change the first day" : "Drag to change the last day")
    }

    private func dayColumn(_ day: Date, width: CGFloat) -> some View {
        let timed = CalendarLayout.events(events, on: day, calendar: calendar).filter { !$0.isAllDay }
        let placements = CalendarTimelinePlacement.layout(timed, day: day, calendar: calendar)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24) { _ in
                    Rectangle().fill(Color.clear).frame(height: hourHeight)
                        .overlay(alignment: .top) { Divider() }
                        .overlay { Rectangle().fill(Tokens.Surface.border).frame(height: Tokens.Border.hairline).opacity(Tokens.Calendar.selectedTint) }
                }
            }
            .contentShape(Rectangle())
            .gesture(pointerGesture(.createTimed).exclusively(before:
                SpatialTapGesture(coordinateSpace: .named(Self.coordinateSpace)).onEnded { value in
                    guard let start = timedDate(at: value.location) else { return }
                    create(CalendarEventRange(start: start, end: start.addingTimeInterval(1800), isAllDay: false))
                }
            ))
            .help("Click or drag to create an event")
            ForEach(placements) { placement in
                let laneWidth = max(Tokens.Space.s1, (width - Tokens.Space.s1_5) / CGFloat(placement.lanes))
                eventCard(placement, day: day)
                    .frame(width: max(Tokens.Space.s1, laneWidth - Tokens.Space.s0_5))
                    .offset(x: CGFloat(placement.lane) * laneWidth + Tokens.Space.s0_5,
                            y: CGFloat(placement.startMinute) / 60 * hourHeight)
            }
            if let preview = previewEvent, !preview.isAllDay,
               let placement = CalendarTimelinePlacement.layout(CalendarLayout.events([preview], on: day, calendar: calendar), day: day, calendar: calendar).first {
                CalendarTimelineEvent(event: preview, selected: true, height: max(Tokens.Space.s6, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight),
                                      calendar: calendar, showsRange: true)
                    .frame(width: max(Tokens.Space.s1, width - Tokens.Space.s1))
                    .offset(x: Tokens.Space.s0_5, y: CGFloat(placement.startMinute) / 60 * hourHeight)
                    .allowsHitTesting(false)
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
        .frame(width: width, height: hourHeight * 24)
        .background { if calendar.isDateInToday(day) { Color.accentColor.opacity(Tokens.Calendar.todayTint) } }
        .background(calendar.isDateInWeekend(day) ? Tokens.Surface.muted : Tokens.Surface.primary)
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.Surface.border).frame(width: Tokens.Border.hairline).allowsHitTesting(false) }
    }

    private func eventCard(_ placement: CalendarTimelinePlacement, day: Date) -> some View {
        let event = placement.event
        return CalendarTimelineEvent(event: event, selected: selectedID == event.id,
                                     height: max(Tokens.Space.s6, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight), calendar: calendar)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { edit(event) }.onTapGesture { selectedID = event.id }
            .gesture(pointerGesture(.move(event, day)), including: event.canEdit ? .all : .subviews)
            .overlay(alignment: .top) {
                if selectedID == event.id, event.canEdit, calendar.isDate(day, inSameDayAs: event.start) { timedHandle(.resizeStart(event)) }
            }
            .overlay(alignment: .bottom) {
                if selectedID == event.id, event.canEdit, calendar.isDate(day, inSameDayAs: event.end.addingTimeInterval(-1)) { timedHandle(.resizeEnd(event)) }
            }
            .opacity(drag?.action.event?.id == event.id ? Tokens.Calendar.selectedTint : 1)
            .accessibilityAddTraits(.isButton).accessibilityAction { edit(event) }
            .accessibilityAction(named: "Extend by 15 minutes") { if event.canEdit { change(event, CalendarInteraction.resizing(event, to: event.end.addingTimeInterval(900), startEdge: false, calendar: calendar)) } }
            .accessibilityAction(named: "Shorten by 15 minutes") { if event.canEdit { change(event, CalendarInteraction.resizing(event, to: event.end.addingTimeInterval(-900), startEdge: false, calendar: calendar)) } }
            .contextMenu { eventMenu(event) }
    }

    private func timedHandle(_ action: CalendarTimelineAction) -> some View {
        Capsule().fill(Color.accentColor).frame(width: Tokens.Space.s6, height: Tokens.Space.s1)
            .frame(maxWidth: .infinity).frame(height: Tokens.Space.s2).contentShape(Rectangle())
            .highPriorityGesture(pointerGesture(action))
            .help(action.isStartEdge ? "Drag to change the start time" : "Drag to change the end time")
    }

    @ViewBuilder private func eventMenu(_ event: CalendarDisplayEvent) -> some View {
        Button("Open event") { edit(event) }
        Button("Duplicate") { duplicate(event) }
        Button("Delete", role: .destructive) { delete(event) }.disabled(!event.canEdit)
    }
}
