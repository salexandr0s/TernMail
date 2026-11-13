import MessageContent
import SwiftUI

/// Month gestures use the whole six-week canvas, so a drag can cross row boundaries.
struct CalendarMonthGrid: View {
    @Environment(\.calendarPresentation) private var presentation
    /// The date shown. `showDate` moves the model's; see `CalendarGridViews`
    /// for why neither it nor `select` is a binding.
    let date: Date
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    let showDate: (Date) -> Void
    /// Sets the selected event. Each chip reads the selection through `CalendarSelectionReader`.
    let select: (String?) -> Void
    let create: (CalendarEventRange) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    let change: @MainActor (CalendarDisplayEvent, CalendarEventRange) async -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    let dropMail: (MailLink, CalendarEventRange) -> Void
    let openDay: (Date) -> Void
    /// The six weeks shown. Hit testing reads them on every pointer move.
    private let days: [Date]
    @Namespace private var canvas
    @State private var drag: MonthDrag?
    @State private var cancelled = false
    @State private var geometryFrames = CalendarGeometryFrames<CalendarMonthRegion>()
    private var frames: [CalendarMonthRegion: CGRect] { geometryFrames.values }
    /// The edge a drag is held near: -1 for the top, 1 for the bottom, 0 for neither.
    @State private var autoScroll: CGFloat = 0
    @GestureState private var pointerIsDown = false

    private enum Action { case create, move, start, end }
    private struct MonthDrag {
        let action: Action
        let originDay: Date
        let event: CalendarDisplayEvent?
        var range: CalendarEventRange?
        /// Set when an event is dropped. The highlight stays on the dropped days until its change is written.
        var commit: UUID?
        var isCommitting: Bool { commit != nil }
    }

    /// A gesture is in progress, as opposed to a drop that is being written.
    private var isDragging: Bool { drag.map { !$0.isCommitting } ?? false }

    init(date: Date, calendar: Calendar, events: [CalendarDisplayEvent],
         showDate: @escaping (Date) -> Void, select: @escaping (String?) -> Void,
         create: @escaping (CalendarEventRange) -> Void, edit: @escaping (CalendarDisplayEvent) -> Void,
         change: @escaping @MainActor (CalendarDisplayEvent, CalendarEventRange) async -> Void,
         delete: @escaping (CalendarDisplayEvent) -> Void, duplicate: @escaping (CalendarDisplayEvent) -> Void,
         dropMail: @escaping (MailLink, CalendarEventRange) -> Void, openDay: @escaping (Date) -> Void) {
        self.date = date
        self.calendar = calendar
        self.events = events
        self.showDate = showDate
        self.select = select
        self.create = create
        self.edit = edit
        self.change = change
        self.delete = delete
        self.duplicate = duplicate
        self.dropMail = dropMail
        self.openDay = openDay
        days = CalendarLayout.monthDays(containing: date, calendar: calendar)
    }

    var body: some View {
        GeometryReader { geometry in
            let cellHeight = max(Tokens.Space.s16 + Tokens.Space.s8,
                                 (geometry.size.height - Tokens.Space.s8 - Tokens.Border.hairline) / 6)
            // The snapshot of another range, such as the week just left, would
            // fill only its own days. Use it once it covers this month.
            let prepared = presentation.flatMap { $0.covers(days, calendar: calendar) ? $0 : nil }
            VStack(spacing: 0) {
                CalendarWeekdayHeader(calendar: calendar).background(Tokens.Surface.muted)
                Divider()
                ScrollView(.vertical) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            cell(day, height: cellHeight, prepared: prepared)
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
            geometryFrames.values = value
            if drag != nil, let pointer = geometryFrames.pointer { updateDrag(at: pointer) }
        }
        .background { CalendarDragCancellation(isActive: isDragging) { cancelDrag() } }
        .onExitCommand { if isDragging { cancelDrag() } }
        .onChange(of: pointerIsDown) { _, down in
            // A dropped event keeps its highlight until its change is written.
            if !down {
                if drag?.isCommitting != true { drag = nil }
                cancelled = false
            }
        }
        .onChange(of: events) { _, current in
            guard let event = drag?.event, current.first(where: { $0.id == event.id }) != event else { return }
            // Once the written change arrives, the event itself sits on the dropped days.
            if drag?.isCommitting == true { drag = nil } else { cancelDrag() }
        }
        .onChange(of: calendar.timeZone) { _, _ in cancelDrag() }
        .onChange(of: days.first) { _, _ in cancelDrag() }
        .onDisappear { drag = nil; cancelled = false }
        .task(id: drag?.commit) {
            guard let commit = drag?.commit else { return }
            do { try await Task.sleep(for: Tokens.Calendar.dropHold) } catch { return }
            if drag?.commit == commit { drag = nil }
        }
    }

    private func cell(_ day: Date, height: CGFloat, prepared: CalendarPresentationSnapshot?) -> some View {
        let dayEvents = prepared.map { $0.day(day)?.events ?? [] }
            ?? CalendarLayout.events(events, on: day, calendar: calendar)
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
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { select(nil); showDate(day) } label: {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.callout.weight(selectedDay || calendar.isDateInToday(day) ? .semibold : .regular))
                            .monospacedDigit().foregroundStyle(currentMonth ? Color.primary : Color.secondary)
                            .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                            .background(calendar.isDateInToday(day) ? Color.accentColor.opacity(Tokens.Calendar.selectedTint) : .clear, in: Circle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Select " + CalendarLayout.format(day, style: .dateTime.month().day(), calendar: calendar))
                }
                ForEach(dayEvents.prefix(limit)) { event in
                    eventChip(event, on: day)
                }
                if dayEvents.count > limit {
                    Button("\(dayEvents.count - limit) more") { openDay(day) }
                        .font(.caption.weight(.medium)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Space.s1).help("Show all events on this day")
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
        CalendarSelectionReader(eventID: event.id) { selected in
            CalendarEventChip(event: event, selected: selected, showsTime: !event.isAllDay, pointer: movePointer(for: event))
                .onTapGesture(count: 2) { edit(event) }
                .onTapGesture { select(event.id) }
                .gesture(gesture(.move, event: event, day: day), including: event.canEdit ? .all : .subviews)
                .overlay(alignment: .leading) {
                    if event.canEdit, event.isAllDay, selected, calendar.isDate(event.start, inSameDayAs: day) {
                        resizeGrip(.start, event: event, day: day)
                    }
                }
                .overlay(alignment: .trailing) {
                    if event.canEdit, event.isAllDay, selected,
                       calendar.isDate(event.end.addingTimeInterval(-1), inSameDayAs: day) {
                        resizeGrip(.end, event: event, day: day)
                    }
                }
        }
            .contextMenu { CalendarEventMenuItems(event: event, edit: edit, duplicate: duplicate, delete: delete) }
            .accessibilityAddTraits(.isButton).accessibilityAction { edit(event) }
            .accessibilityAction(named: "Duplicate") { duplicate(event) }
    }

    /// Editable events show the open hand, and the closed hand while they move.
    private func movePointer(for event: CalendarDisplayEvent) -> PointerStyle? {
        guard event.canEdit else { return nil }
        if let drag, drag.action == .move, drag.event?.id == event.id, !cancelled, !drag.isCommitting { return .grabActive }
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
                // A new gesture takes over from a drop that is still being written.
                if drag?.isCommitting == true { drag = nil }
                if drag == nil {
                    drag = MonthDrag(action: action, originDay: day, event: event)
                    select(event?.id)
                }
                updateDrag(at: value.location)
            }
            .onEnded { value in
                guard drag?.isCommitting != true else { cancelled = false; return }
                updateDrag(at: value.location)
                let finished = drag
                let wasCancelled = cancelled
                cancelled = false
                guard !wasCancelled, let finished, let range = finished.range else { drag = nil; return }
                guard let moved = finished.event else { drag = nil; create(range); return }
                guard moved.canEdit, events.first(where: { $0.id == moved.id }) == moved,
                      range != CalendarEventRange(moved) else { drag = nil; return }
                commit(moved, to: range)
            }
    }

    private func frameReader(_ region: CalendarMonthRegion) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CalendarMonthFrames.self, value: [region: geometry.frame(in: .named(canvas))])
        }
    }

    /// What the auto-scroll view is given: the edge the drag is held near, while there is a drag.
    private var scrollDirection: CGFloat {
        guard !cancelled, let drag, !drag.isCommitting else { return 0 }
        return autoScroll
    }

    private func edgeDirection(at pointer: CGPoint) -> CGFloat {
        guard let viewport = frames[.viewport], viewport.contains(pointer) else { return 0 }
        if pointer.y < viewport.minY + Tokens.Space.s8 { return -1 }
        if pointer.y > viewport.maxY - Tokens.Space.s8 { return 1 }
        return 0
    }

    private func updateDrag(at point: CGPoint) {
        guard !cancelled, var active = drag, !active.isCommitting else { return }
        geometryFrames.pointer = point
        active.range = day(at: point).map { range(for: active, target: $0) }
        // Most pointer moves stay on one day. Setting state only on a change
        // keeps them from rebuilding the grid.
        if active.range != drag?.range { drag = active }
        let direction = edgeDirection(at: point)
        if direction != autoScroll { autoScroll = direction }
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
        guard let active = drag else { return }
        // After the drop there is no gesture left to cancel, only a highlight to remove.
        if !active.isCommitting { cancelled = true }
        drag = nil
    }

    /// Keeps the highlight on the dropped days while the change is written. It
    /// goes when `events` shows the change, when the change returns without one
    /// (the editor opened, or the change was refused) or after
    /// `Tokens.Calendar.dropHold`.
    private func commit(_ event: CalendarDisplayEvent, to range: CalendarEventRange) {
        let id = UUID()
        drag?.commit = id
        Task {
            await change(event, range)
            if drag?.commit == id { drag = nil }
        }
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
