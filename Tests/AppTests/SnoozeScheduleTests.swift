import Foundation
import Testing
@testable import Tern

@Suite struct SnoozeScheduleTests {
    /// New York, Sunday first, Saturday and Sunday weekend. 2026-10-28 is a
    /// Wednesday, and daylight saving time ends on Sunday 2026-11-01.
    private func schedule(firstWeekday: Int = 1) throws -> SnoozeSchedule {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        calendar.firstWeekday = firstWeekday
        return SnoozeSchedule(calendar: calendar)
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10, in schedule: SnoozeSchedule) throws -> Date {
        try #require(schedule.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }

    @Test func midweekMorningOffersEveryPreset() throws {
        let schedule = try schedule()
        let options = schedule.options(now: try date(28, 10, in: schedule))
        #expect(options == [
            .init(preset: .laterToday, wakeAt: try date(28, 18, in: schedule)),
            .init(preset: .tomorrow, wakeAt: try date(29, 8, in: schedule)),
            .init(preset: .thisWeekend, wakeAt: try date(31, 8, in: schedule)),
            .init(preset: .nextWeek, wakeAt: try date(1, 8, month: 11, in: schedule)),
        ])
        // 8 AM on the Sunday the clocks go back is 13:00 UTC.
        #expect(options.last?.wakeAt == Date(timeIntervalSince1970: 1_793_538_000))
    }

    @Test func laterTodayEndsAtFivePM() throws {
        let schedule = try schedule()
        #expect(schedule.options(now: try date(28, 16, 59, in: schedule)).first?.preset == .laterToday)
        #expect(schedule.options(now: try date(28, 17, in: schedule)).first?.preset == .tomorrow)
        #expect(schedule.options(now: try date(28, 23, 30, in: schedule)).first?.wakeAt == (try date(29, 8, in: schedule)))
    }

    @Test func weekendAndWeekBoundaries() throws {
        let sundayFirst = try schedule()
        // Friday: Tomorrow is Saturday 8 AM, so This Weekend would repeat it.
        let friday = sundayFirst.options(now: try date(30, 18, in: sundayFirst)).map(\.preset)
        #expect(friday == [.tomorrow, .nextWeek])
        // Saturday is already the weekend, and next week starts tomorrow.
        let saturday = sundayFirst.options(now: try date(31, 9, in: sundayFirst)).map(\.preset)
        #expect(saturday == [.laterToday, .tomorrow])

        // With Monday first, next week starts on Monday.
        let mondayFirst = try schedule(firstWeekday: 2)
        #expect(mondayFirst.wakeTime(for: .nextWeek, now: try date(28, 10, in: mondayFirst)) == (try date(2, 8, month: 11, in: mondayFirst)))
        let sunday = mondayFirst.options(now: try date(1, 18, month: 11, in: mondayFirst)).map(\.preset)
        #expect(sunday == [.tomorrow])
    }
}
