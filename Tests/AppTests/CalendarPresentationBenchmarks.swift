import Foundation
import GmailAPI
import Testing
@testable import Tern

/// Component timings are separate from the native visible-frame benchmark.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERN_BENCHMARKS"] == "1"), .serialized)
struct CalendarPresentationBenchmarks {
    @Test(arguments: [100, 1_000])
    func preparedCalendarNavigation(eventCount: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        calendar.firstWeekday = 2
        let start = try #require(calendar.date(from: DateComponents(year: 2030, month: 1, day: 7)))
        let end = try #require(calendar.date(byAdding: .day, value: 7, to: start))
        let events = (0..<eventCount).map { index in
            let beginning = start.addingTimeInterval(Double((index % 7) * 86_400 + ((index / 7) % 20) * 3_600))
            return CalendarDisplayEvent(event: GoogleCalendarEvent(id: "event-\(index)", summary: "Synthetic event",
                start: CalendarDateTime(date: beginning), end: CalendarDateTime(date: beginning.addingTimeInterval(1_800))),
                accountID: "synthetic", calendarID: "work", fallbackTimeZoneID: calendar.timeZone.identifier)
        }
        let clock = ContinuousClock()
        let preparedAt = clock.now
        let snapshot = CalendarPresentationSnapshot(events: events, interval: DateInterval(start: start, end: end),
            calendar: calendar, buildsTimeAxis: true)
        let preparedDuration = preparedAt.duration(to: clock.now)
        var samples: [Duration] = []
        var consumed = 0
        for _ in 0..<100 {
            let before = clock.now
            for day in snapshot.days { consumed += snapshot.day(day)?.placements.count ?? 0 }
            samples.append(before.duration(to: clock.now))
        }
        #expect(consumed == eventCount * 100)
        let sorted = samples.sorted()
        print("calendar \(eventCount) events: prepare=\(preparedDuration), 100 warm lookups p50=\(sorted[49]), p95=\(sorted[94]), p99=\(sorted[98])")
    }
}
