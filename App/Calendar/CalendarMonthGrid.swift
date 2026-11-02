import MessageContent
import SwiftUI

/// Month gestures use the whole six-week canvas, so a drag can cross row boundaries.
struct CalendarMonthGrid: View {
    @Environment(\.calendarPresentation) private var presentation
    @Binding var date: Date
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    @Binding var selectedID: String?
    let create: (CalendarEventRange) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    let change: (CalendarDisplayEvent, CalendarEventRange) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    let dropMail: (MailLink, CalendarEventRange) -> Void
    let openDay: (Date) -> Void
    @Namespace private var canvas
    @State private var drag: MonthDrag?
    @State private var cancelled = false
    @State private var frames: [CalendarMonthRegion: CGRect] = [:]
    @GestureState private var pointerIsDown = false

    private enum Action { case create, move, start, end }
    private struct MonthDrag {
        let action: Action
        let originDay: Date
        let event: CalendarDisplayEvent?
        var pointer: CGPoint
        var range: CalendarEventRange?
    }

    private var days: [Date] { CalendarLayout.monthDays(containing: date, calendar: calendar) }

    var body: some View {
        GeometryReader { geometry in
            let cellHeight = max(Tokens.Space.s16 + Tokens.Space.s8,
                                 (geometry.size.height - Tokens.Space.s8 - Tokens.Border.hairline) / 6)
            VStack(spacing: 0) {
                CalendarWeekdayHeader(calendar: calendar).background(Tokens.Surface.muted)
                Divider()
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            cell(day, height: cellHeight)
                        }
                    }
                    .background { frameReader(.content) }
                    .background { CalendarDragAutoScroll(direction: scrollDirection) }
                    .background { PerformanceScrollSurfaceMarker(name: "calendar", isActive: true) }
                }
                .background { frameReader(.viewport) }
            }
        }
        .coordinateSpace(.named(canvas))
        .dropDestination(for: ConversationDragItem.self) { items, location in
            guard let item = items.first, let day = day(at: location) else { return false }
            dropMail(item.link, dayRange(day))
            return true
        }
        .onPreferenceChange(CalendarMonthFrames.self) { value in
            frames = value
            if let drag { updateDrag(at: drag.pointer) }
        }
        .background { CalendarDragCancellation(isActive: drag != nil) { cancelDrag() } }
        .onExitCommand { cancelDrag() }
        .onChange(of: pointerIsDown) { _, down in
            if !down { drag = nil; cancelled = false }
        }
        .onChange(of: events) { _, current in
            if let event = drag?.event, current.first(where: { $0.id == event.id }) != event { cancelDrag() }
        }
        .onChange(of: calendar.timeZone) { _, _ in cancelDrag() }
        .onChange(of: days.first) { _, _ in cancelDrag() }
        .onDisappear { drag = nil; cancelled = false }
    }

    private func cell(_ day: Date, height: CGFloat) -> some View {
        let dayEvents = presentation?.matches(calendar) == true
            ? presentation?.day(day)?.events ?? [] : CalendarLayout.events(events, on: day, calendar: calendar)
        let capacity = max(1, Int((height - Tokens.Space.s10) / (Tokens.Space.s6 + Tokens.Space.s0_5)))
        let limit = dayEvents.count > capacity ? max(1, capacity - 1) : capacity
        let currentMonth = calendar.isDate(day, equalTo: date, toGranularity: .month)
        let selectedDay = calendar.isDate(day, inSameDayAs: date)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear)
                .contentShape(Rectangle())
                .ternHover(radius: 0)
                .gesture(gesture(.create, day: day).exclusively(before: TapGesture().onEnded { create(dayRange(day)) }))
                .contextMenu { Button("New All-Day Event") { create(dayRange(day)) } }
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                HStack {
                    if calendar.component(.day, from: day) == 1 {
                        Text(CalendarLayout.format(day, style: .dateTime.month(.abbreviated), calendar: calendar))
                            .font(.caption.bold()).foregroundStyle(currentMonth ? Color.primary : Color.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { selectedID = nil; date = day } label: {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.callout.weight(selectedDay || calendar.isDateInToday(day) ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(calendar.isDateInToday(day) ? Color(nsColor: .alternateSelectedControlTextColor)
                                : currentMonth ? Color.primary : Color.secondary)
                            .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                            .background(calendar.isDateInToday(day) ? Color.accentColor : .clear, in: Circle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Select " + CalendarLayout.format(day, style: .dateTime.month().day(), calendar: calendar))
                        .accessibilityValue(calendar.isDateInToday(day) ? "Today" : "")
                        .accessibilityAddTraits(selectedDay ? .isSelected : [])
                }
                ForEach(dayEvents.prefix(limit)) { event in
                    eventChip(event, on: day)
                }
                if dayEvents.count > limit {
                    Button { openDay(day) } label: {
                        HStack(spacing: Tokens.Space.s1) {
                            Text("\(dayEvents.count - limit) more")
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }
                    }
                        .font(.caption.bold()).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Space.s1).help("Show all events on this day")
                        .accessibilityLabel("Show \(dayEvents.count - limit) more events on "
                            + CalendarLayout.format(day, style: .dateTime.month().day(), calendar: calendar))
                }
                Spacer(minLength: 0)
            }.padding(Tokens.Space.s1)
            if includesPreview(day) {
                Rectangle().fill(Color.accentColor.opacity(Tokens.Calendar.selectedTint))
                    .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: Tokens.Border.focus) }
                    .overlay(alignment: .bottomLeading) {
                        Text(drag?.event?.title ?? "New event").font(.caption.weight(.medium)).lineLimit(1)
                            .padding(Tokens.Space.s1)
                    }.allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(currentMonth && !calendar.isDateInWeekend(day) ? Tokens.Surface.primary : Tokens.Surface.muted)
        .overlay { if selectedDay { Rectangle().strokeBorder(Color.accentColor, lineWidth: Tokens.Border.focus).allowsHitTesting(false) } }
        .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.Surface.border).frame(width: Tokens.Border.hairline).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month().day(), calendar: calendar))
        .accessibilityAction(named: "New all-day event") { create(dayRange(day)) }
    }

    private func eventChip(_ event: CalendarDisplayEvent, on day: Date) -> some View {
        CalendarEventChip(event: event, selected: selectedID == event.id, showsTime: !event.isAllDay, pointer: movePointer(for: event))
            .onTapGesture(count: 2) { edit(event) }
            .onTapGesture { selectedID = event.id }
            .gesture(gesture(.move, event: event, day: day), including: event.canEdit ? .all : .subviews)
            .overlay(alignment: .leading) {
                if event.canEdit, event.isAllDay, selectedID == event.id, calendar.isDate(event.start, inSameDayAs: day) {
                    resizeGrip(.start, event: event, day: day)
                }
            }
            .overlay(alignment: .trailing) {
                if event.canEdit, event.isAllDay, selectedID == event.id,
                   calendar.isDate(event.end.addingTimeInterval(-1), inSameDayAs: day) {
                    resizeGrip(.end, event: event, day: day)
                }
            }
            .contextMenu { CalendarEventMenuItems(event: event, edit: edit, duplicate: duplicate, delete: delete) }
            .accessibilityAddTraits(.isButton).accessibilityAction { edit(event) }
            .accessibilityAction(named: "Duplicate") { duplicate(event) }
    }

    /// Editable events show the open hand, and the closed hand while they move.
    private func movePointer(for event: CalendarDisplayEvent) -> PointerStyle? {
        guard event.canEdit else { return nil }
        if let drag, drag.action == .move, drag.event?.id == event.id, !cancelled { return .grabActive }
        return .grabIdle
    }

    private func resizeGrip(_ action: Action, event: CalendarDisplayEvent, day: Date) -> some View {
        Capsule().fill(Color.accentColor).frame(width: Tokens.Space.s0_5, height: Tokens.Space.s3)
            .frame(width: Tokens.Space.s2, height: Tokens.Space.s6).contentShape(Rectangle())
            .ternResizeCursor(.horizontal)
            .highPriorityGesture(gesture(action, event: event, day: day))
            .help(action == .start ? "Drag to change the first day" : "Drag to change the last day")
    }

    private func gesture(_ action: Action, event: CalendarDisplayEvent? = nil, day: Date) -> some Gesture {
        DragGesture(minimumDistance: Tokens.Space.s1, coordinateSpace: .named(canvas))
            .updating($pointerIsDown) { _, state, _ in state = true }
            .onChanged { value in
                guard !cancelled, event?.canEdit != false else { return }
                if drag == nil {
                    drag = MonthDrag(action: action, originDay: day, event: event, pointer: value.location)
                    selectedID = event?.id
                }
                updateDrag(at: value.location)
            }
            .onEnded { value in
                updateDrag(at: value.location)
                let finished = drag
                let wasCancelled = cancelled
                drag = nil; cancelled = false
                guard !wasCancelled, let finished, let range = finished.range else { return }
                if let event = finished.event {
                    guard event.canEdit, events.first(where: { $0.id == event.id }) == event,
                          range != CalendarEventRange(event) else { return }
                    change(event, range)
                } else { create(range) }
            }
    }

    private func frameReader(_ region: CalendarMonthRegion) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CalendarMonthFrames.self, value: [region: geometry.frame(in: .named(canvas))])
        }
    }

    private var scrollDirection: CGFloat {
        guard !cancelled, let drag, let viewport = frames[.viewport], viewport.contains(drag.pointer) else { return 0 }
        if drag.pointer.y < viewport.minY + Tokens.Space.s8 { return -1 }
        if drag.pointer.y > viewport.maxY - Tokens.Space.s8 { return 1 }
        return 0
    }

    private func updateDrag(at point: CGPoint) {
        guard !cancelled, var active = drag else { return }
        active.pointer = point
        active.range = day(at: point).map { range(for: active, target: $0) }
        drag = active
    }

    /// The day under a point in the canvas, while it is inside the visible grid.
    private func day(at point: CGPoint) -> Date? {
        guard let viewport = frames[.viewport], viewport.contains(point), let content = frames[.content],
              let index = CalendarMonthHitTesting.index(at: CGPoint(x: point.x - content.minX, y: point.y - content.minY),
                                                        width: content.width, rowHeight: content.height / 6),
              days.indices.contains(index) else { return nil }
        return days[index]
    }

    private func range(for drag: MonthDrag, target: Date) -> CalendarEventRange {
        guard let event = drag.event else {
            return CalendarInteraction.selection(from: drag.originDay, to: target, allDay: true, calendar: calendar)
        }
        switch drag.action {
        case .move:
            return CalendarInteraction.moving(event, from: drag.originDay, to: target, calendar: calendar)
        case .start:
            return CalendarInteraction.resizing(event, to: target, startEdge: true, calendar: calendar)
        case .end:
            return CalendarInteraction.resizing(event, to: target, startEdge: false, calendar: calendar)
        case .create: return dayRange(target)
        }
    }

    private func dayRange(_ day: Date) -> CalendarEventRange {
        CalendarInteraction.selection(from: day, to: day, allDay: true, calendar: calendar)
    }

    private func includesPreview(_ day: Date) -> Bool {
        guard let range = drag?.range, let end = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        return range.start < end && range.end > day
    }

    private func cancelDrag() {
        if drag != nil { cancelled = true; drag = nil }
    }
}

enum CalendarMonthHitTesting {
    static func index(at point: CGPoint, width: CGFloat, rowHeight: CGFloat) -> Int? {
        guard width > 0, rowHeight > 0, point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x < width, point.y >= 0, point.y < rowHeight * 6 else { return nil }
        return Int(point.y / rowHeight) * 7 + Int(point.x / (width / 7))
    }
}

private enum CalendarMonthRegion: Hashable { case content, viewport }
private struct CalendarMonthFrames: PreferenceKey {
    static let defaultValue: [CalendarMonthRegion: CGRect] = [:]
    static func reduce(value: inout [CalendarMonthRegion: CGRect], nextValue: () -> [CalendarMonthRegion: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
