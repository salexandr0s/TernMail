import GmailAPI
import SwiftUI

/// Native scrolling changes hit-test coordinates without changing event content.
/// The owning grid keeps this reference for its lifetime; active drags publish
/// their updated range separately after each geometry update.
@MainActor
final class CalendarGeometryFrames<Region: Hashable> {
    var values: [Region: CGRect] = [:]
    /// Where the pointer of the drag in progress last was. It moves on every
    /// mouse event, far more often than the range it gives, so it is not view state.
    var pointer: CGPoint?
}

enum CalendarTimelineRegion: Hashable, Sendable { case canvas, allDay, content, viewport }
struct CalendarTimelineFrames: PreferenceKey {
    static let defaultValue: [CalendarTimelineRegion: CGRect] = [:]
    static func reduce(value: inout [CalendarTimelineRegion: CGRect], nextValue: () -> [CalendarTimelineRegion: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension View {
    func calendarTimelineFrame(_ region: CalendarTimelineRegion) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: CalendarTimelineFrames.self,
                                   value: [region: geometry.frame(in: .named(CalendarTimeGrid.coordinateSpace))])
        })
    }
}

enum CalendarTimelineAction {
    case createTimed, createAllDay
    case move(CalendarDisplayEvent, Date)
    case resizeStart(CalendarDisplayEvent), resizeEnd(CalendarDisplayEvent)
    var event: CalendarDisplayEvent? {
        switch self {
        case .createTimed, .createAllDay: nil
        case .move(let event, _), .resizeStart(let event), .resizeEnd(let event): event
        }
    }
    var isStartEdge: Bool { if case .resizeStart = self { true } else { false } }
}

struct CalendarTimelineDrag {
    var action: CalendarTimelineAction
    var anchor: Date
    var range: CalendarEventRange?
    /// Set when an event is dropped. The preview then stays at the dropped slot
    /// until the change is written, so the event does not go back to its old
    /// slot in between.
    var commit: UUID?
    var isCommitting: Bool { commit != nil }
}

extension CalendarTimeGrid {
    var previewEvent: CalendarDisplayEvent? {
        guard !dragCancelled, let drag, let range = drag.range else { return nil }
        let preview = drag.action.event ?? CalendarDisplayEvent(
            event: GoogleCalendarEvent(id: "selection", summary: "New event"), accountID: "", calendarID: "")
        return CalendarDisplayEvent(event: range.applying(to: preview.event, calendar: calendar),
            accountID: preview.accountID, calendarID: preview.calendarID, colorHex: preview.colorHex,
            isPending: preview.isPending, canEdit: preview.canEdit, fallbackTimeZoneID: calendar.timeZone.identifier)
    }

    /// What the auto-scroll view is given: the edge the drag is held near, while there is a drag.
    var scrollDirection: CGFloat {
        guard !dragCancelled, let drag, !drag.isCommitting else { return 0 }
        return autoScroll
    }

    /// -1 near the top of the hours and 1 near the bottom, for a drag that can change the time of day.
    private func edgeDirection(of action: CalendarTimelineAction, at pointer: CGPoint) -> CGFloat {
        guard let viewport = frames[.viewport], let canvas = frames[.canvas],
              canvas.contains(pointer), pointer.x >= viewport.minX + gutter,
              pointer.x < viewport.maxX else { return 0 }
        switch action {
        case .createAllDay: return 0
        case .resizeStart(let event), .resizeEnd(let event): if event.isAllDay { return 0 }
        case .createTimed, .move: break
        }
        if pointer.y >= viewport.minY, pointer.y < viewport.minY + Tokens.Space.s8 { return -1 }
        if pointer.y <= viewport.maxY, pointer.y > viewport.maxY - Tokens.Space.s8 { return 1 }
        return 0
    }

    func pointerGesture(_ action: CalendarTimelineAction) -> some Gesture {
        DragGesture(minimumDistance: Tokens.Space.s1, coordinateSpace: .named(Self.coordinateSpace))
            .updating($pointerIsDown) { _, state, _ in state = true }
            .onChanged { value in
                guard !dragCancelled else { return }
                // A new gesture takes over from a drop that is still being written.
                if drag == nil || drag?.isCommitting == true {
                    guard action.event?.canEdit != false else { return }
                    let anchor: Date?
                    switch action {
                    case .createAllDay: anchor = allDayDate(at: value.startLocation)
                    case .move(let event, let visibleDay):
                        anchor = event.isAllDay ? visibleDay : timedDate(at: value.startLocation, snapped: false)
                    case .resizeStart(let event), .resizeEnd(let event):
                        anchor = event.isAllDay ? allDayDate(at: value.startLocation) : timedDate(at: value.startLocation)
                    case .createTimed: anchor = timedDate(at: value.startLocation)
                    }
                    guard let anchor else { return }
                    select(action.event?.id)
                    drag = CalendarTimelineDrag(action: action, anchor: anchor)
                }
                updateDrag(at: value.location)
            }
            .onEnded { value in
                guard !dragCancelled, let active = drag, !active.isCommitting else {
                    if drag?.isCommitting != true { drag = nil }
                    dragCancelled = false
                    return
                }
                updateDrag(at: value.location)
                guard let session = drag, let range = session.range, range.end > range.start else { drag = nil; return }
                guard let source = session.action.event else { drag = nil; create(range); return }
                guard source.canEdit, let current = events.first(where: { $0.id == source.id }), current == source,
                      range != CalendarEventRange(source) else { drag = nil; return }
                commit(source, to: range)
            }
    }

    /// Keeps the preview and the dimmed source where the event was dropped while
    /// the change is written. They go when `events` shows the change, when the
    /// change returns without one (the editor opened, or the change was refused)
    /// or after `Tokens.Calendar.dropHold`.
    func commit(_ source: CalendarDisplayEvent, to range: CalendarEventRange) {
        let id = UUID()
        drag?.commit = id
        Task {
            await change(source, range)
            if drag?.commit == id { drag = nil }
        }
    }

    func cancelDrag() {
        guard let active = drag else { return }
        // After the drop there is no gesture left to cancel, only a preview to remove.
        if active.isCommitting { drag = nil; return }
        dragCancelled = true
        drag?.range = nil
    }

    func updateDrag(at point: CGPoint) {
        guard !dragCancelled, var session = drag, !session.isCommitting else { return }
        geometryFrames.pointer = point
        let timed = timedDate(at: point, allowEndOfDay: true)
        let allDay = allDayDate(at: point)
        switch session.action {
        case .createTimed:
            session.range = timed.map { CalendarInteraction.selection(from: session.anchor, to: $0, allDay: false, calendar: calendar) }
        case .createAllDay:
            session.range = allDay.map { CalendarInteraction.selection(from: session.anchor, to: $0, allDay: true, calendar: calendar) }
        case .move(let event, let visibleDay):
            if let allDay {
                let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.start), to: calendar.startOfDay(for: visibleDay)).day ?? 0
                let start = calendar.date(byAdding: .day, value: -dayOffset, to: allDay) ?? allDay
                session.range = CalendarInteraction.moving(event, to: start, allDay: true, calendar: calendar)
            } else if let target = timedDate(at: point, snapped: false) {
                session.range = CalendarInteraction.dragging(event, from: session.anchor, to: target, calendar: calendar)
            } else { session.range = nil }
        case .resizeStart(let event), .resizeEnd(let event):
            let target = event.isAllDay ? allDay : timed
            session.range = target.map {
                $0 == session.anchor ? CalendarEventRange(event)
                    : CalendarInteraction.resizing(event, to: $0, startEdge: session.action.isStartEdge, calendar: calendar)
            }
        }
        // Most pointer moves stay inside one 15-minute step. Setting state only
        // on a change keeps them from rebuilding the grid.
        if session.range != drag?.range { drag = session }
        let direction = edgeDirection(of: session.action, at: point)
        if direction != autoScroll { autoScroll = direction }
    }

    func allDayDate(at point: CGPoint) -> Date? {
        guard let frame = frames[.allDay], frame.contains(point), frames[.canvas]?.contains(point) == true else { return nil }
        return day(at: point.x, in: frame)
    }

    func timedDate(at point: CGPoint, snapped: Bool = true, allowEndOfDay: Bool = false) -> Date? {
        guard let viewport = frames[.viewport], let content = frames[.content],
              viewport.contains(point), frames[.canvas]?.contains(point) == true,
              point.y >= content.minY, point.y <= content.maxY,
              let day = day(at: point.x, in: content) else { return nil }
        let minute = Double((point.y - content.minY) / hourHeight * 60)
        return timeAxis.date(atMinute: minute, on: day, snapped: snapped, allowEndOfDay: allowEndOfDay)
    }

    private func day(at x: CGFloat, in frame: CGRect) -> Date? {
        let width = (frame.width - gutter) / CGFloat(max(1, days.count))
        guard width > 0, x >= frame.minX + gutter, x < frame.maxX else { return nil }
        let index = Int((x - frame.minX - gutter) / width)
        return days.indices.contains(index) ? days[index] : nil
    }
}
