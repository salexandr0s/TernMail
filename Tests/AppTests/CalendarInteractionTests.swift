import Foundation
import GmailAPI
import Testing
@testable import Tern

@Suite struct CalendarInteractionTests {
    @Test func calendarFilePreparationAndExportRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.ics")
        let calendar = try calendar()
        let original = event(start: try date(24, calendar: calendar), end: try date(26, calendar: calendar),
                             allDay: true, calendar: calendar).event
        try await CalendarImportExport.write([original], to: url)
        let fileItems = try await CalendarImportExport.prepare(.file(url))
        let textItems = try await CalendarImportExport.prepare(.text(String(contentsOf: url, encoding: .utf8)))
        let restored = try #require(fileItems.first?.event)
        #expect(fileItems.count == 1)
        #expect(restored.summary == original.summary)
        #expect(restored.start?.date == original.start?.date)
        #expect(restored.end?.date == original.end?.date)
        #expect(textItems.map(\.event) == fileItems.map(\.event))
        await #expect(throws: CalendarImportExport.ImportError.self) {
            try await CalendarImportExport.prepare(.text(String(repeating: "x", count: 4 * 1024 * 1024 + 1)))
        }
    }

    @MainActor @Test func cancelledCalendarFileWorkDoesNotReadOrOverwrite() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("keep existing content".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let write = Task { @MainActor in try await CalendarImportExport.write([], to: url) }
        write.cancel()
        await #expect(throws: CancellationError.self) { try await write.value }
        #expect(try Data(contentsOf: url) == original)
        let read = Task { @MainActor in
            try await CalendarImportExport.prepare(.file(url.appendingPathExtension("missing")))
        }
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
    }

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
        let midnight = try date(31, calendar: calendar)
        let late = midnight.addingTimeInterval(-900)
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
        var recurring = original.event
        recurring.rawValue["futureField"] = .object(["keep": .bool(true)])
        recurring.attendees = [CalendarAttendee(email: "guest@example.invalid")]
        recurring.recurrence = ["RRULE:FREQ=WEEKLY"]
        original = original.replacingEvent(recurring)
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

    @Test func snappingClampsCreationAndAllowsMidnightForResizing() throws {
        let calendar = try calendar()
        let day = try date(30, calendar: calendar)
        let midnight = try date(31, calendar: calendar)
        let axis = CalendarTimeAxis(days: [day], calendar: calendar)
        #expect(axis.date(atMinute: -20, on: day) == day)
        #expect(axis.date(atMinute: 37, on: day) == day.addingTimeInterval(30 * 60))
        #expect(axis.date(atMinute: 38, on: day) == day.addingTimeInterval(45 * 60))
        #expect(axis.date(atMinute: 1500, on: day) == midnight.addingTimeInterval(-15 * 60))
        #expect(axis.date(atMinute: 1500, on: day, allowEndOfDay: true) == midnight)
        #expect(axis.date(atMinute: 1500, on: day, snapped: false) == midnight.addingTimeInterval(-60))
    }

    @Test func dragIntoTheRepeatedHourKeepsTheSecondPass() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let day = try date(25, calendar: calendar)
        let firstPass = day.addingTimeInterval(2 * 3600 + 900)
        let secondPass = day.addingTimeInterval(3 * 3600 + 900)
        #expect(calendar.dateComponents([.hour, .minute], from: firstPass) == calendar.dateComponents([.hour, .minute], from: secondPass))
        let original = event(start: firstPass.addingTimeInterval(-3600), end: firstPass, allDay: false, calendar: calendar)
        let grabbed = original.start.addingTimeInterval(600)
        // Two real hours later, plus four minutes that the snap rounds away.
        let moved = CalendarInteraction.dragging(original, from: grabbed, to: grabbed.addingTimeInterval(2 * 3600 + 240), calendar: calendar)
        #expect(moved.start == secondPass)
        #expect(moved.end == secondPass.addingTimeInterval(3600))
        #expect(CalendarInteraction.dragging(original, from: grabbed, to: grabbed, calendar: calendar) == CalendarEventRange(original))
    }
}
