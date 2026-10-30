import Foundation

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
