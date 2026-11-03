import Foundation
import Testing
@testable import Tern

@Suite struct CalendarEventDatePickerTests {
    @MainActor @Test func changingDayKeepsEventZoneClockTimeAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let original = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 9, minute: 30)))
        let nextDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29)))
        let result = CalendarEventDatePicker.selection(on: nextDay, preserving: original, allDay: false, calendar: calendar)
        let values = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: result)
        #expect(values == DateComponents(year: 2026, month: 3, day: 29, hour: 9, minute: 30))
        #expect(result.timeIntervalSince(original) == 23 * 3600)
        #expect(CalendarEventDatePicker.selection(on: nextDay, preserving: original, allDay: true, calendar: calendar)
            == calendar.startOfDay(for: nextDay))
    }

    @MainActor @Test func skippedClockTimeMovesByTheGapAndRepeatedTimeUsesFirstOccurrence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let original = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 2, minute: 30)))
        let spring = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29)))
        let springResult = CalendarEventDatePicker.selection(on: spring, preserving: original, allDay: false, calendar: calendar)
        #expect(calendar.component(.hour, from: springResult) == 3)
        #expect(calendar.component(.minute, from: springResult) == 30)
        #expect(calendar.isDate(springResult, inSameDayAs: spring))

        let autumn = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        let autumnResult = CalendarEventDatePicker.selection(on: autumn, preserving: original, allDay: false, calendar: calendar)
        #expect(calendar.component(.hour, from: autumnResult) == 2)
        #expect(calendar.component(.minute, from: autumnResult) == 30)
        #expect(calendar.timeZone.secondsFromGMT(for: autumnResult) == 2 * 3600)
        let secondOccurrence = autumnResult.addingTimeInterval(3600)
        #expect(calendar.timeZone.secondsFromGMT(for: secondOccurrence) == 3600)
        #expect(CalendarEventDatePicker.selection(on: autumn, preserving: secondOccurrence, allDay: false, calendar: calendar)
            == secondOccurrence)
        // The recurrence control displays a timed UNTIL as a date-only value.
        #expect(CalendarEventDatePicker.selection(on: autumn, preserving: secondOccurrence, allDay: true, calendar: calendar)
            == secondOccurrence)
    }
}
