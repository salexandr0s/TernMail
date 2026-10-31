import GmailAPI
import SwiftUI

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
    var pointer: CGPoint
    var range: CalendarEventRange?
}

extension CalendarTimeGrid {
    var previewEvent: CalendarDisplayEvent? {
        guard !dragCancelled, let drag, let range = drag.range else { return nil }
        var preview = drag.action.event ?? CalendarDisplayEvent(
            event: GoogleCalendarEvent(id: "selection", summary: "New event"), accountID: "", calendarID: "")
        preview.event = range.applying(to: preview.event, calendar: calendar)
        preview.fallbackTimeZoneID = calendar.timeZone.identifier
        return preview
    }

    var scrollDirection: CGFloat {
        guard !dragCancelled, let drag, let viewport = frames[.viewport], let canvas = frames[.canvas],
              canvas.contains(drag.pointer), drag.pointer.x >= viewport.minX + gutter,
              drag.pointer.x < viewport.maxX else { return 0 }
        switch drag.action {
        case .createAllDay: return 0
        case .resizeStart(let event), .resizeEnd(let event): if event.isAllDay { return 0 }
        case .createTimed, .move: break
        }
        if drag.pointer.y >= viewport.minY, drag.pointer.y < viewport.minY + Tokens.Space.s8 { return -1 }
        if drag.pointer.y <= viewport.maxY, drag.pointer.y > viewport.maxY - Tokens.Space.s8 { return 1 }
        return 0
    }

    func pointerGesture(_ action: CalendarTimelineAction) -> some Gesture {
        DragGesture(minimumDistance: Tokens.Space.s1, coordinateSpace: .named(Self.coordinateSpace))
            .updating($pointerIsDown) { _, state, _ in state = true }
            .onChanged { value in
                guard !dragCancelled else { return }
                if drag == nil {
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
                    selectedID = action.event?.id
                    drag = CalendarTimelineDrag(action: action, anchor: anchor, pointer: value.location)
                }
                updateDrag(at: value.location)
            }
            .onEnded { value in
                defer { drag = nil; dragCancelled = false }
                guard !dragCancelled, drag != nil else { return }
                updateDrag(at: value.location)
                guard let drag, let range = drag.range, range.end > range.start else { return }
                if let source = drag.action.event {
                    guard source.canEdit, let current = events.first(where: { $0.id == source.id }), current == source,
                          range != CalendarEventRange(source) else { return }
                    change(source, range)
                } else { create(range) }
            }
    }

    func cancelDrag() {
        guard drag != nil else { return }
        dragCancelled = true
        drag?.range = nil
    }

    func updateDrag(at point: CGPoint) {
        guard !dragCancelled, var session = drag else { return }
        session.pointer = point
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
        drag = session
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
