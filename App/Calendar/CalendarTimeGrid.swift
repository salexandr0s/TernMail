import MessageContent
import SwiftUI

/// Where the hours of the day and week grids are scrolled to. `CalendarView`
/// keeps one, so the position outlives a grid that Month, Year, Schedule or
/// search results replaced. A scroll position a person has moved no longer
/// names a point, so the grid records the offset itself.
///
/// A plain reference and not view state: the offset changes on every scrolled
/// frame and no view draws from it.
@MainActor
final class CalendarHourScroll {
    var offset: CGFloat?
}

struct CalendarTimeGrid: View {
    let date: Date
    let isWeek: Bool
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    let prepared: CalendarPresentationSnapshot?
    let days: [Date]
    let timeAxis: CalendarTimeAxis
    /// Sets the selected event. Each card reads the selection through
    /// `CalendarSelectionReader`; see `CalendarGridViews` for why this is not a binding.
    let select: (String?) -> Void
    let create: (CalendarEventRange) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    let change: @MainActor (CalendarDisplayEvent, CalendarEventRange) async -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    let dropMail: (MailLink, CalendarEventRange) -> Void
    let hourHeight = Tokens.Space.s16
    let gutter = CalendarTimeGrid.gutterWidth
    nonisolated static let gutterWidth = Tokens.Space.s16
    static let coordinateSpace = "calendarTimeline"

    /// Narrower than this the days scroll sideways. `CalendarView` uses the same
    /// width to decide whether a horizontal swipe scrolls them or changes the period.
    nonisolated static func minimumWidth(dayCount: Int) -> CGFloat {
        gutterWidth + CGFloat(dayCount) * Tokens.Calendar.dayMinWidth
    }

    // Internal, not private: the drag gesture in CalendarTimelineGesture.swift reads and sets these.
    @State var geometryFrames = CalendarGeometryFrames<CalendarTimelineRegion>()
    var frames: [CalendarTimelineRegion: CGRect] { geometryFrames.values }
    @State var drag: CalendarTimelineDrag?
    @State var dragCancelled = false
    /// The edge a drag is held near: -1 for the top, 1 for the bottom, 0 for neither.
    @State var autoScroll: CGFloat = 0
    @GestureState var pointerIsDown = false
    /// Starts where the owner last saw the hours, and without one at 8 AM: the
    /// top padding plus the `hourHeight` rows above it, which are eight unless
    /// the clocks change earlier in the days shown. A user's scroll replaces
    /// the point, so the grid is never pulled back to it.
    @State private var hourScroll: ScrollPosition
    private let hourScrollStore: CalendarHourScroll?

    #if TERN_TEST_SUPPORT
    static var onBodyEvaluation: ((CalendarTimeGrid) -> Void)?
    #endif

    init(date: Date, isWeek: Bool, calendar: Calendar, events: [CalendarDisplayEvent],
         presentation: CalendarPresentationSnapshot? = nil, select: @escaping (String?) -> Void,
         create: @escaping (CalendarEventRange) -> Void, edit: @escaping (CalendarDisplayEvent) -> Void,
         change: @escaping @MainActor (CalendarDisplayEvent, CalendarEventRange) async -> Void,
         delete: @escaping (CalendarDisplayEvent) -> Void,
         duplicate: @escaping (CalendarDisplayEvent) -> Void, dropMail: @escaping (MailLink, CalendarEventRange) -> Void,
         hourScroll store: CalendarHourScroll? = nil) {
        self.date = date
        self.isWeek = isWeek
        self.calendar = calendar
        self.events = events
        days = Self.days(showing: date, isWeek: isWeek, calendar: calendar)
        prepared = presentation?.matches(calendar) == true && presentation?.days == days && presentation?.timeAxis != nil
            ? presentation : nil
        self.select = select
        self.create = create
        self.edit = edit
        self.change = change
        self.delete = delete
        self.duplicate = duplicate
        self.dropMail = dropMail
        let axis = prepared?.timeAxis ?? CalendarTimeAxis(days: days, calendar: calendar)
        timeAxis = axis
        hourScrollStore = store
        _hourScroll = State(initialValue: ScrollPosition(
            y: store?.offset ?? Tokens.Space.s2 + CGFloat(axis.row(ofHour: 8)) * Tokens.Space.s16))
    }

    private static func days(showing date: Date, isWeek: Bool, calendar: Calendar) -> [Date] {
        guard let interval = calendar.dateInterval(of: isWeek ? .weekOfYear : .day, for: date) else { return [] }
        return CalendarLayout.days(in: interval, calendar: calendar)
    }

    var body: some View {
        #if TERN_TEST_SUPPORT
        let _ = Self.onBodyEvaluation?(self)
        #endif
        let axis = timeAxis
        // Built once for all the day columns: making it encodes and parses the event's dates.
        let preview = previewEvent
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width, Self.minimumWidth(dayCount: days.count))
            let columnWidth = (contentWidth - gutter) / CGFloat(max(1, days.count))
            ScrollView(.horizontal) {
                timeline(columnWidth: columnWidth, axis: axis, preview: preview)
                    .frame(width: contentWidth, height: geometry.size.height)
            }
            .calendarTimelineFrame(.canvas)
        }
        .coordinateSpace(.named(Self.coordinateSpace))
        .dropDestination(for: ConversationDragItem.self) { items, location in
            guard let item = items.first, let range = dropRange(at: location) else { return false }
            dropMail(item.link, range)
            return true
        }
        .onPreferenceChange(CalendarTimelineFrames.self) { value in
            geometryFrames.values = value
            if drag != nil, !dragCancelled, let pointer = geometryFrames.pointer { updateDrag(at: pointer) }
        }
        .background { CalendarDragCancellation(isActive: drag != nil && drag?.isCommitting != true) { cancelDrag() } }
        .onChange(of: pointerIsDown) { _, isDown in
            // A dropped event keeps its preview until its change is written.
            if !isDown {
                if drag?.isCommitting != true { drag = nil }
                dragCancelled = false
            }
        }
        .onChange(of: events) { _, current in
            guard let source = drag?.action.event, current.first(where: { $0.id == source.id }) != source else { return }
            // Once the written change arrives, the event itself sits at the dropped slot.
            if drag?.isCommitting == true { drag = nil } else { cancelDrag() }
        }
        .onChange(of: date) { _, _ in cancelDrag() }
        .onChange(of: isWeek) { _, _ in cancelDrag() }
        .onChange(of: calendar.timeZone.identifier) { _, _ in cancelDrag() }
        .onChange(of: calendar.firstWeekday) { _, _ in cancelDrag() }
        .onDisappear { drag = nil; dragCancelled = false }
        .task(id: drag?.commit) {
            guard let commit = drag?.commit else { return }
            do { try await Task.sleep(for: Tokens.Calendar.dropHold) } catch { return }
            if drag?.commit == commit { drag = nil }
        }
    }

    /// A drop in the hours lane starts a half-hour event there; in the all-day lane, an all-day one.
    private func dropRange(at point: CGPoint) -> CalendarEventRange? {
        if let start = timedDate(at: point) {
            return CalendarEventRange(start: start, end: start.addingTimeInterval(1800), isAllDay: false)
        }
        if let day = allDayDate(at: point) {
            return CalendarInteraction.selection(from: day, to: day, allDay: true, calendar: calendar)
        }
        return nil
    }

    private func timeline(columnWidth: CGFloat, axis: CalendarTimeAxis, preview: CalendarDisplayEvent?) -> some View {
        VStack(spacing: 0) {
            dayHeaders(columnWidth: columnWidth)
            Divider()
            allDayLane(columnWidth: columnWidth, preview: preview)
            Divider()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<axis.rows.count, id: \.self) { row in
                            Text(CalendarLayout.format(axis.rowDates[row], style: .dateTime.hour(), calendar: calendar))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: gutter - Tokens.Space.s2, height: hourHeight, alignment: .topTrailing)
                                .padding(.trailing, Tokens.Space.s2)
                        }
                    }
                    ForEach(days, id: \.self) { day in dayColumn(day, width: columnWidth, axis: axis, preview: preview) }
                }
                .calendarTimelineFrame(.content)
                .background { CalendarDragAutoScroll(direction: scrollDirection) }
                .background { PerformanceScrollSurfaceMarker(name: "calendar", isActive: true) }
                .padding(.top, Tokens.Space.s2)
            }
            .scrollPosition($hourScroll)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                hourScrollStore?.offset = offset
            }
            .calendarTimelineFrame(.viewport)
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

    private func allDayLane(columnWidth: CGFloat, preview: CalendarDisplayEvent?) -> some View {
        let rowCount = days.map { allDayEvents(on: $0).count }.max() ?? 0
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
                            ForEach(allDayEvents(on: day)) { event in
                                allDayChip(event, day: day)
                            }
                            if let preview, preview.isAllDay,
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
        CalendarSelectionReader(eventID: event.id) { selected in
            CalendarEventChip(event: event, selected: selected, showsTime: false, pointer: movePointer(for: event))
                .onTapGesture(count: 2) { edit(event) }.onTapGesture { select(event.id) }
                .gesture(pointerGesture(.move(event, day)), including: event.canEdit ? .all : .subviews)
                .overlay(alignment: .leading) {
                    if selected, event.canEdit, calendar.isDate(day, inSameDayAs: event.start) {
                        allDayHandle(.resizeStart(event))
                    }
                }
                .overlay(alignment: .trailing) {
                    if selected, event.canEdit, calendar.isDate(day, inSameDayAs: event.end.addingTimeInterval(-1)) {
                        allDayHandle(.resizeEnd(event))
                    }
                }
        }
            .opacity(drag?.action.event?.id == event.id ? Tokens.Calendar.selectedTint : 1)
            .accessibilityAddTraits(.isButton).accessibilityAction { edit(event) }
            .contextMenu { eventMenu(event) }
    }

    /// Editable events show the open hand, and the closed hand while they move.
    private func movePointer(for event: CalendarDisplayEvent) -> PointerStyle? {
        guard event.canEdit else { return nil }
        if case .move(let moving, _) = drag?.action, moving.id == event.id, !dragCancelled,
           drag?.isCommitting != true { return .grabActive }
        return .grabIdle
    }

    private func allDayHandle(_ action: CalendarTimelineAction) -> some View {
        Capsule().fill(Color.accentColor).frame(width: Tokens.Space.s1, height: Tokens.Space.s3)
            .frame(width: Tokens.Space.s2, height: Tokens.Space.s6).contentShape(Rectangle())
            .ternResizeCursor(.horizontal)
            .highPriorityGesture(pointerGesture(action))
            .help(action.isStartEdge ? "Drag to change the first day" : "Drag to change the last day")
    }

    private func dayColumn(_ day: Date, width: CGFloat, axis: CalendarTimeAxis, preview: CalendarDisplayEvent?) -> some View {
        let placements = prepared.map { $0.day(day)?.placements ?? [] } ?? CalendarTimelinePlacement.layout(
            CalendarLayout.events(events, on: day, calendar: calendar).filter { !$0.isAllDay }, day: day, axis: axis)
        let missingRows = axis.rows.indices.filter { !axis.has(row: $0, on: day) }
        return ZStack(alignment: .topLeading) {
            CalendarHourLines(rowCount: axis.rows.count, missingRows: missingRows, rowHeight: hourHeight)
            .equatable()
            .overlay(alignment: .top) {
                ForEach(missingRows, id: \.self) { row in missingHour(axis.rows[row], at: row) }
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
                let cardWidth = max(Tokens.Space.s1, laneWidth - Tokens.Space.s0_5)
                eventCard(placement, day: day, isCompact: cardWidth < Tokens.Calendar.compactCardWidth)
                    .frame(width: cardWidth)
                    .offset(x: CGFloat(placement.lane) * laneWidth + Tokens.Space.s0_5,
                            y: CGFloat(placement.startMinute) / 60 * hourHeight)
            }
            if let preview, !preview.isAllDay,
               let placement = CalendarTimelinePlacement.layout(CalendarLayout.events([preview], on: day, calendar: calendar), day: day, axis: axis).first {
                CalendarTimelineEvent(event: preview, selected: true, height: max(Tokens.Space.s6, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight),
                                      calendar: calendar, showsRange: true)
                    .frame(width: max(Tokens.Space.s1, width - Tokens.Space.s1))
                    .offset(x: Tokens.Space.s0_5, y: CGFloat(placement.startMinute) / 60 * hourHeight)
                    .allowsHitTesting(false)
            }
            if calendar.isDateInToday(day) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let minute = axis.minute(of: context.date, on: day).rounded(.down)
                    Rectangle().fill(Color.accentColor).frame(height: Tokens.Border.focus)
                        .overlay(alignment: .leading) { Circle().fill(Color.accentColor).frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5) }
                        .offset(y: CGFloat(minute) / 60 * hourHeight)
                }.allowsHitTesting(false)
            }
        }
        .frame(width: width, height: hourHeight * CGFloat(axis.rows.count))
        .background { if calendar.isDateInToday(day) { Color.accentColor.opacity(Tokens.Calendar.todayTint) } }
        .background(calendar.isDateInWeekend(day) ? Tokens.Surface.muted : Tokens.Surface.primary)
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(Tokens.Surface.border).frame(width: Tokens.Border.hairline).allowsHitTesting(false) }
    }

    /// A row of a week that this day's clock never shows: the hour it skips, or
    /// the repeat of an hour that only another day has. `CalendarHourLines`
    /// shades the row; this lies over it and explains it.
    private func missingHour(_ row: CalendarTimeAxis.Row, at index: Int) -> some View {
        Rectangle().fill(Color.clear).contentShape(Rectangle())
            .frame(height: hourHeight)
            .help(row.pass > 0 ? "This hour repeats only on the day the clocks go back" : "The clocks skip this hour on this day")
            .padding(.top, CGFloat(index) * hourHeight)
    }

    private func eventCard(_ placement: CalendarTimelinePlacement, day: Date, isCompact: Bool) -> some View {
        let event = placement.event
        let height = max(Tokens.Space.s6, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight)
        return CalendarSelectionReader(eventID: event.id) { selected in
            CalendarTimelineEvent(event: event, selected: selected, height: height, calendar: calendar, isCompact: isCompact)
                .contentShape(Rectangle())
                .ternHover(pointer: movePointer(for: event))
                .onTapGesture(count: 2) { edit(event) }.onTapGesture { select(event.id) }
                .gesture(pointerGesture(.move(event, day)), including: event.canEdit ? .all : .subviews)
                .overlay(alignment: .top) {
                    if selected, event.canEdit, calendar.isDate(day, inSameDayAs: event.start) { timedHandle(.resizeStart(event)) }
                }
                .overlay(alignment: .bottom) {
                    if selected, event.canEdit, calendar.isDate(day, inSameDayAs: event.end.addingTimeInterval(-1)) { timedHandle(.resizeEnd(event)) }
                }
        }
            .opacity(drag?.action.event?.id == event.id ? Tokens.Calendar.selectedTint : 1)
            .accessibilityAddTraits(.isButton).accessibilityAction { edit(event) }
            .accessibilityAction(named: "Extend by 15 minutes") { resize(event, by: 900) }
            .accessibilityAction(named: "Shorten by 15 minutes") { resize(event, by: -900) }
            .contextMenu { eventMenu(event) }
    }

    /// The VoiceOver resize actions write through the same change as a drag.
    private func resize(_ event: CalendarDisplayEvent, by seconds: TimeInterval) {
        guard event.canEdit else { return }
        let range = CalendarInteraction.resizing(event, to: event.end.addingTimeInterval(seconds), startEdge: false, calendar: calendar)
        Task { await change(event, range) }
    }

    private func timedHandle(_ action: CalendarTimelineAction) -> some View {
        Capsule().fill(Color.accentColor).frame(width: Tokens.Space.s6, height: Tokens.Space.s1)
            .frame(maxWidth: .infinity).frame(height: Tokens.Space.s2).contentShape(Rectangle())
            .ternResizeCursor(.vertical)
            .highPriorityGesture(pointerGesture(action))
            .help(action.isStartEdge ? "Drag to change the start time" : "Drag to change the end time")
    }

    private func eventMenu(_ event: CalendarDisplayEvent) -> some View {
        CalendarEventMenuItems(event: event, edit: edit, duplicate: duplicate, delete: delete)
    }

    private func allDayEvents(on day: Date) -> [CalendarDisplayEvent] {
        if let prepared { return prepared.day(day)?.allDay ?? [] }
        return CalendarLayout.events(events, on: day, calendar: calendar).filter(\.isAllDay)
    }
}

/// One day's hour lines, its fainter half-hour lines and the shading of the
/// rows its clock never shows, drawn in one pass. A week had three views per
/// row for these, about five hundred in all.
private struct CalendarHourLines: View, Equatable {
    @Environment(\.displayScale) private var displayScale
    // Read in `body` so the lines are drawn again in the new colors when either changes.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let rowCount: Int
    let missingRows: [Int]
    let rowHeight: CGFloat

    nonisolated static func ==(lhs: Self, rhs: Self) -> Bool {
        lhs.rowCount == rhs.rowCount && lhs.missingRows == rhs.missingRows && lhs.rowHeight == rhs.rowHeight
    }

    var body: some View {
        let _ = (colorScheme, contrast)
        let scale = displayScale
        Canvas { context, size in
            let hour = GraphicsContext.Shading.color(Tokens.Surface.border)
            let halfHour = GraphicsContext.Shading.color(Tokens.Surface.border.opacity(Tokens.Calendar.selectedTint))
            let line = Tokens.Border.hairline
            for row in missingRows {
                context.fill(Path(CGRect(x: 0, y: CGFloat(row) * rowHeight, width: size.width, height: rowHeight)), with: hour)
            }
            for row in 0..<rowCount {
                let top = CGFloat(row) * rowHeight
                context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: line)), with: hour)
                // Half a point off the pixel grid would blur the line on a 1x display.
                let middle = ((top + (rowHeight - line) / 2) * scale).rounded() / scale
                context.fill(Path(CGRect(x: 0, y: middle, width: size.width, height: line)), with: halfHour)
            }
        }
    }
}
