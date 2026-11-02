import Foundation

/// The hour rows of the day and week grids, and how a point in them maps to
/// real time.
///
/// A row is one clock hour. On an ordinary day the grid has the 24 hours and a
/// point's distance from the top is the time since midnight. A day when the
/// clocks change keeps only the hours it has: the hour spring skips has no row,
/// and the hour autumn repeats gets two. A week shows every row any of its days
/// has, so the columns stay aligned. A row one day lacks takes no time in that
/// day's column: every point in it is the moment the clocks change.
struct CalendarTimeAxis: Sendable {
    /// A clock hour, and which time through it: the repeat after the clocks go back is pass 1.
    struct Row: Hashable, Sendable {
        var hour: Int
        var pass: Int
    }

    /// A stretch of one day that its clock spends in one row.
    private struct Slot: Sendable {
        var row: Int
        /// Minutes from the top of the grid to where the stretch starts.
        var top: Double
        var interval: DateInterval
        var bottom: Double { top + interval.duration / 60 }
    }

    /// A stretch of one day before rows are numbered. `minute` is the clock
    /// minute it starts at, which is 0 unless the clocks changed within the hour.
    private typealias Stretch = (row: Row, minute: Double, interval: DateInterval)

    let rows: [Row]
    /// The first instant in each row, which its label shows.
    let rowDates: [Date]
    private let calendar: Calendar
    private let slots: [Date: [Slot]]

    /// Minutes from the top of the grid to the bottom.
    var minuteCount: Int { rows.count * 60 }

    init(days: [Date], calendar: Calendar) {
        self.calendar = calendar
        var rows: [Row] = []
        var firstDates: [Row: Date] = [:]
        var stretches: [Date: [Stretch]] = [:]
        for day in days {
            guard let bounds = calendar.dateInterval(of: .day, for: day) else { continue }
            let hours = Self.stretches(in: bounds, calendar: calendar)
            stretches[bounds.start] = hours
            // A row only this day has goes right after the row before it, so
            // every day's hours stay in order.
            var previous = -1
            for hour in hours {
                if let index = rows.firstIndex(of: hour.row) {
                    previous = index
                } else {
                    previous += 1
                    rows.insert(hour.row, at: previous)
                    firstDates[hour.row] = hour.interval.start
                }
            }
        }
        let index = Dictionary(rows.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        self.rows = rows
        rowDates = rows.map { firstDates[$0] ?? .distantPast }
        slots = stretches.mapValues { hours in
            hours.compactMap { hour in
                index[hour.row].map { Slot(row: $0, top: Double($0 * 60) + hour.minute, interval: hour.interval) }
            }
        }
    }

    /// The real span of `day`, or nil for a day the axis doesn't show.
    func bounds(of day: Date) -> DateInterval? {
        guard let slots = slots[calendar.startOfDay(for: day)], let first = slots.first, let last = slots.last else { return nil }
        return DateInterval(start: first.interval.start, end: last.interval.end)
    }

    /// Minutes from the top of the grid to `date` in the column for `day`.
    /// A date outside the day sits at the column's top or bottom edge.
    func minute(of date: Date, on day: Date) -> Double {
        guard let slots = slots[calendar.startOfDay(for: day)], let first = slots.first, let last = slots.last else { return 0 }
        guard date > first.interval.start else { return first.top }
        guard let slot = slots.first(where: { date < $0.interval.end }) else { return last.bottom }
        return slot.top + date.timeIntervalSince(slot.interval.start) / 60
    }

    /// The instant `minute` minutes from the top of the grid in the column for
    /// `day`, rounded to a quarter hour when `snapped` and to a whole minute
    /// otherwise. A new event can't start at midnight, so unless `allowEndOfDay`
    /// is set the latest instant is one step before the day ends.
    func date(atMinute minute: Double, on day: Date, snapped: Bool = true, allowEndOfDay: Bool = false) -> Date? {
        guard minute.isFinite, let slots = slots[calendar.startOfDay(for: day)], let last = slots.last else { return nil }
        let step = Double(snapped ? CalendarInteraction.snapMinutes : 1)
        let position = min(Double(minuteCount), max(0, (minute / step).rounded() * step))
        let date = slots.first(where: { position < $0.bottom })
            .map { $0.interval.start.addingTimeInterval(max(0, position - $0.top) * 60) } ?? last.interval.end
        return allowEndOfDay ? date : min(date, last.interval.end.addingTimeInterval(-step * 60))
    }

    /// The row where `hour` first starts, for opening the grid at a set time.
    func row(ofHour hour: Int) -> Int {
        rows.firstIndex(of: Row(hour: hour, pass: 0)) ?? min(hour, max(0, rows.count - 1))
    }

    /// Whether the clock on `day` passes through the row at `index`.
    func has(row index: Int, on day: Date) -> Bool {
        slots[calendar.startOfDay(for: day)]?.contains { $0.row == index } ?? false
    }

    /// Splits a day into the stretches its clock spends in each hour, in order.
    /// A stretch ends at the next hour or where the clocks change, and the clock
    /// going back into an hour starts another pass through it.
    private static func stretches(in bounds: DateInterval, calendar: Calendar) -> [Stretch] {
        var change = calendar.timeZone.nextDaylightSavingTimeTransition(after: bounds.start)
        if bounds.duration == 24 * 3600, change.map({ $0 >= bounds.end }) ?? true {
            // Most days: the clocks don't change, so the day is 24 even hours from midnight.
            return (0..<24).map { hour in
                (row: Row(hour: hour, pass: 0), minute: 0,
                 interval: DateInterval(start: bounds.start.addingTimeInterval(Double(hour * 3600)), duration: 3600))
            }
        }
        var result: [Stretch] = []
        var passes: [Int: Int] = [:]
        var start = bounds.start
        while start < bounds.end {
            let clock = calendar.dateComponents([.hour, .minute, .second], from: start)
            let hour = clock.hour ?? 0
            let minute = Double((clock.minute ?? 0) * 60 + (clock.second ?? 0)) / 60
            var end = min(bounds.end, start.addingTimeInterval((60 - minute) * 60))
            if let next = change, next > start, next < end { end = next }
            let pass: Int
            if let last = result.last, last.row.hour == hour, minute >= last.minute + last.interval.duration / 60 {
                pass = last.row.pass // The clock jumped forward within the hour.
            } else {
                pass = passes[hour, default: 0]
                passes[hour] = pass + 1
            }
            result.append((row: Row(hour: hour, pass: pass), minute: minute, interval: DateInterval(start: start, end: end)))
            if let next = change, end >= next { change = calendar.timeZone.nextDaylightSavingTimeTransition(after: end) }
            start = end
        }
        return result
    }
}
