import Foundation
import GmailAPI
import Testing
@testable import Tern

@Suite struct CalendarInteractionTests {
    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        return calendar
    }

    private func date(_ day: Int, hour: Int = 0, minute: Int = 0, calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
    }

    private func event(start: Date, end: Date, allDay: Bool, calendar: Calendar) -> CalendarDisplayEvent {
        CalendarDisplayEvent(event: GoogleCalendarEvent(id: "event", summary: "Meeting",
            start: CalendarDateTime(date: start, timeZone: calendar.timeZone, allDay: allDay),
            end: CalendarDateTime(date: end, timeZone: calendar.timeZone, allDay: allDay)),
            accountID: "account", calendarID: "calendar", fallbackTimeZoneID: calendar.timeZone.identifier)
    }

    @Test func backwardSelectionsAndMidnightKeepPositiveExclusiveRanges() throws {
        let calendar = try calendar()
        let day = try date(30, calendar: calendar)
        let midnight = CalendarInteraction.date(at: 1440, on: day, calendar: calendar)
        #expect(midnight == calendar.date(byAdding: .day, value: 1, to: day))
        let late = CalendarInteraction.date(at: 1425, on: day, calendar: calendar)
        let interval = CalendarInteraction.selection(from: midnight, to: late, allDay: false, calendar: calendar)
        #expect(interval.start == late)
        #expect(interval.end == midnight)
        let same = CalendarInteraction.selection(from: late, to: late, allDay: false, calendar: calendar)
        #expect(same.end.timeIntervalSince(same.start) == 900)
        let earlier = try date(28, calendar: calendar)
        let allDay = CalendarInteraction.selection(from: day, to: earlier, allDay: true, calendar: calendar)
        #expect(allDay.start == earlier)
        #expect(allDay.end == midnight)
    }

    @Test func allDayMovesPreserveCivilDaysAcrossDaylightSavingChange() throws {
        let calendar = try calendar()
        let original = event(start: try date(24, calendar: calendar), end: try date(26, calendar: calendar), allDay: true, calendar: calendar)
        #expect(original.end.timeIntervalSince(original.start) == 49 * 3600)
        let moved = CalendarInteraction.moving(original, to: try date(28, calendar: calendar), calendar: calendar)
        #expect(moved.end == (try date(30, calendar: calendar)))
        #expect(moved.end.timeIntervalSince(moved.start) == 48 * 3600)
        let grabbedSecondDay = CalendarInteraction.moving(original, from: try date(25, calendar: calendar),
                                                         to: try date(29, calendar: calendar), calendar: calendar)
        #expect(grabbedSecondDay == moved)
    }

    @Test func timedMovesPreserveDurationAndMonthMovesPreserveWallClock() throws {
        let calendar = try calendar()
        let original = event(start: try date(24, hour: 9, minute: 15, calendar: calendar),
                             end: try date(24, hour: 10, minute: 45, calendar: calendar), allDay: false, calendar: calendar)
        let moved = CalendarInteraction.moving(original, from: try date(24, calendar: calendar),
                                              to: try date(26, calendar: calendar), calendar: calendar)
        #expect(moved.start == (try date(26, hour: 9, minute: 15, calendar: calendar)))
        #expect(moved.end.timeIntervalSince(moved.start) == 90 * 60)
    }

    @Test func conversionUsesCoveredDaysAndIndependentTimedDuration() throws {
        let calendar = try calendar()
        let overnight = event(start: try date(29, hour: 23, calendar: calendar), end: try date(31, calendar: calendar), allDay: false, calendar: calendar)
        let allDay = CalendarInteraction.moving(overnight, to: try date(27, calendar: calendar), allDay: true, calendar: calendar)
        #expect(allDay.end == (try date(29, calendar: calendar)))
        let display = event(start: allDay.start, end: allDay.end, allDay: true, calendar: calendar)
        let timed = CalendarInteraction.moving(display, to: try date(30, hour: 11, calendar: calendar), allDay: false, calendar: calendar)
        #expect(!timed.isAllDay)
        #expect(timed.end.timeIntervalSince(timed.start) == 3600)
    }

    @Test func resizingCannotInvertEventsAndKeepsUntouchedEdge() throws {
        let calendar = try calendar()
        let original = event(start: try date(30, hour: 9, calendar: calendar), end: try date(30, hour: 10, calendar: calendar), allDay: false, calendar: calendar)
        let start = CalendarInteraction.resizing(original, to: original.end.addingTimeInterval(3600), startEdge: true, calendar: calendar)
        #expect(start.end == original.end)
        #expect(start.start == original.end.addingTimeInterval(-900))
        let end = CalendarInteraction.resizing(original, to: original.start.addingTimeInterval(-3600), startEdge: false, calendar: calendar)
        #expect(end.start == original.start)
        #expect(end.end == original.start.addingTimeInterval(900))
    }

    @Test func applyingRangeRetainsMetadataAndUsesCivilDatesOnConversion() throws {
        let calendar = try calendar()
        var original = event(start: try date(30, hour: 9, calendar: calendar), end: try date(30, hour: 10, calendar: calendar), allDay: false, calendar: calendar)
        original.event.rawValue["futureField"] = .object(["keep": .bool(true)])
        original.event.attendees = [CalendarAttendee(email: "guest@example.invalid")]
        original.event.recurrence = ["RRULE:FREQ=WEEKLY"]
        let range = CalendarInteraction.moving(original, to: try date(31, calendar: calendar), allDay: true, calendar: calendar)
        let changed = range.applying(to: original.event, calendar: calendar)
        #expect(changed.start?.date == "2026-10-31")
        #expect(changed.end?.date == "2026-11-01")
        #expect(changed.rawValue["futureField"] == original.event.rawValue["futureField"])
        #expect(changed.attendees == original.event.attendees)
        #expect(changed.recurrence == original.event.recurrence)
        #expect(Set(changed.changedFields(from: original.event).keys) == Set(["start", "end"]))
    }

    @Test func resizingOneEdgePreservesOtherEdgeRepresentation() throws {
        let calendar = try calendar()
        let original = GoogleCalendarEvent(id: "event", summary: "Meeting",
            start: CalendarDateTime(dateTime: "2026-10-30T09:00:00+01:00"),
            end: CalendarDateTime(dateTime: "2026-10-30T10:00:00+01:00"))
        let range = CalendarEventRange(start: try date(30, hour: 8, minute: 45, calendar: calendar),
                                       end: try date(30, hour: 10, calendar: calendar), isAllDay: false)
        let changed = range.applying(to: original, calendar: calendar)
        #expect(changed.end == original.end)
        #expect(Set(changed.changedFields(from: original).keys) == Set(["start"]))
    }

    @Test func snappingClampsCreationAndAllowsMidnightForResizing() {
        #expect(CalendarInteraction.snappedMinute(at: -20, hourHeight: 60) == 0)
        #expect(CalendarInteraction.snappedMinute(at: 37, hourHeight: 60) == 30)
        #expect(CalendarInteraction.snappedMinute(at: 38, hourHeight: 60) == 45)
        #expect(CalendarInteraction.snappedMinute(at: 1500, hourHeight: 60) == 1425)
        #expect(CalendarInteraction.snappedMinute(at: 1500, hourHeight: 60, allowEndOfDay: true) == 1440)
    }
}
