import Foundation

struct CalendarTimelinePlacement: Identifiable, Sendable {
    var event: CalendarDisplayEvent
    /// Minutes from the top of the grid, as `CalendarTimeAxis` measures them.
    var startMinute: Int
    var endMinute: Int
    var lane: Int
    var lanes: Int
    var id: String { event.id }

    static func layout(_ events: [CalendarDisplayEvent], day: Date, axis: CalendarTimeAxis) -> [Self] {
        guard let bounds = axis.bounds(of: day) else { return [] }
        var result: [Self] = []
        var group: [Self] = []
        var laneEnds: [Int] = []
        var groupEnd = 0
        func flush() {
            result += group.map { value in var copy = value; copy.lanes = laneEnds.count; return copy }
            group = []; laneEnds = []; groupEnd = 0
        }
        for event in events.sorted(by: { $0.start < $1.start }) {
            let start = Int(axis.minute(of: event.start, on: day).rounded(.down))
            let bottom = Int(axis.minute(of: event.end, on: day).rounded(.down))
            let end = event.end >= bounds.end ? bottom : max(start + 15, bottom)
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
