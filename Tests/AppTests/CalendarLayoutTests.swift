import AppKit
import Foundation
import GmailAPI
import SwiftUI
import Testing
@testable import Tern

@Suite struct CalendarLayoutTests {
    @Test func monthDragFindsDaysAcrossWeekRowsAndRejectsOutsideCanvas() {
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 699, y: 99), width: 700, rowHeight: 100) == 6)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 0, y: 100), width: 700, rowHeight: 100) == 7)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 699, y: 599), width: 700, rowHeight: 100) == 41)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 700, y: 50), width: 700, rowHeight: 100) == nil)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 10, y: -1), width: 700, rowHeight: 100) == nil)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 10, y: 600), width: 700, rowHeight: 100) == nil)
    }

    private func calendar() throws -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        value.firstWeekday = 2
        return value
    }

    private func event(_ id: String, start: Date, end: Date) -> CalendarDisplayEvent {
        CalendarDisplayEvent(event: GoogleCalendarEvent(id: id, summary: id,
            start: CalendarDateTime(date: start), end: CalendarDateTime(date: end)),
            accountID: "account", calendarID: "calendar")
    }

    @Test func overlappingEventsReceiveIndependentLanesAndLaterEventsRecoverWidth() throws {
        let calendar = try calendar()
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30)))
        let a = event("a", start: CalendarLayout.date(at: 540, on: day, calendar: calendar), end: CalendarLayout.date(at: 600, on: day, calendar: calendar))
        let b = event("b", start: CalendarLayout.date(at: 570, on: day, calendar: calendar), end: CalendarLayout.date(at: 660, on: day, calendar: calendar))
        let c = event("c", start: CalendarLayout.date(at: 660, on: day, calendar: calendar), end: CalendarLayout.date(at: 720, on: day, calendar: calendar))
        let result = CalendarTimelinePlacement.layout([c, b, a], day: day, calendar: calendar)
        #expect(result.map(\.lane) == [0, 1, 0])
        #expect(result.map(\.lanes) == [2, 2, 1])
    }

    @Test func allDayDateUsesDisplayTimeZoneAndExclusiveEnd() throws {
        let calendar = try calendar()
        let event = CalendarDisplayEvent(event: GoogleCalendarEvent(id: "all-day", summary: "Trip",
            start: CalendarDateTime(date: "2026-10-24"), end: CalendarDateTime(date: "2026-10-26")),
            accountID: "account", calendarID: "calendar", fallbackTimeZoneID: calendar.timeZone.identifier)
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 24)))
        let last = try #require(calendar.date(byAdding: .day, value: 1, to: first))
        let after = try #require(calendar.date(byAdding: .day, value: 2, to: first))
        #expect(event.start == first)
        #expect(event.end == after)
        #expect(CalendarLayout.events([event], on: first, calendar: calendar).count == 1)
        #expect(CalendarLayout.events([event], on: last, calendar: calendar).count == 1)
        #expect(CalendarLayout.events([event], on: after, calendar: calendar).isEmpty)
        #expect(after.timeIntervalSince(first) == 49 * 3600)
    }

    @Test func monthGridUsesConfiguredWeekStartAcrossYearBoundary() throws {
        let calendar = try calendar()
        let january = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
        let days = CalendarLayout.monthDays(containing: january, calendar: calendar)
        #expect(days.count == 42)
        #expect(calendar.component(.weekday, from: try #require(days.first)) == 2)
        #expect(days.contains(january))
        #expect(calendar.component(.year, from: try #require(days.first)) == 2026)
    }

    @Test func copyingMeetingOccurrenceCreatesPrivateIndependentIdentity() throws {
        let start = Date(timeIntervalSince1970: 1_793_353_200)
        var original = GoogleCalendarEvent(id: "series_instance", summary: "Review",
            start: CalendarDateTime(date: start), end: CalendarDateTime(date: start.addingTimeInterval(1800)))
        original.iCalUID = "organizer-meeting@example.invalid"
        original.recurringEventId = "series"
        original.originalStartTime = original.start
        original.organizer = CalendarPerson(email: "organizer@example.invalid")
        original.attendees = [CalendarAttendee(email: "guest@example.invalid")]
        original.hangoutLink = "https://meet.google.com/example"
        original.conferenceData = .googleMeet(requestID: "source-request")
        let data = Data(try CalendarImportExport.clipboardString(for: original).utf8)
        let copy = try #require(CalendarImportExport.parse(data).first?.event)
        #expect(copy.summary == original.summary)
        #expect(copy.startDate == original.startDate)
        #expect(copy.iCalUID != original.iCalUID)
        #expect(copy.recurringEventId == nil)
        #expect(copy.originalStartTime == nil)
        #expect(copy.recurrence == nil)
        #expect(copy.attendees?.isEmpty != false)
        #expect(copy.organizer == nil)
        #expect(copy.hangoutLink == nil)
        #expect(copy.conferenceData == nil)
    }

    @Test func changingTitlePreservesUneditedDatesDefaultsAndUnknownFields() throws {
        let calendar = try calendar()
        var original = GoogleCalendarEvent(id: "meeting", summary: "Original",
            start: CalendarDateTime(dateTime: "2026-10-30T09:00:00+01:00"),
            end: CalendarDateTime(dateTime: "2026-10-30T10:00:00+01:00"))
        original.rawValue["futureField"] = .object(["keep": .bool(true)])
        original.rawValue["source"] = .object(["title": .string("Preserved metadata")])
        var values = CalendarEditorValues(event: original, calendar: calendar)
        #expect(values.applying(to: original, calendar: calendar, timeZone: calendar.timeZone) == original)
        values.title = "Updated"
        let updated = values.applying(to: original, calendar: calendar, timeZone: calendar.timeZone)
        #expect(updated.changedFields(from: original) == ["summary": .string("Updated")])
        #expect(updated.start?.dateTime == "2026-10-30T09:00:00+01:00")
        #expect(updated.reminders == nil)
        #expect(updated.rawValue["futureField"] == original.rawValue["futureField"])
        #expect(updated.rawValue["source"] == original.rawValue["source"])
    }

    @Test func arrowsStepInsideTheViewWhileOptionArrowsChangeThePeriod() {
        #expect(CalendarDisplayMode.day.stepComponent == .day)
        #expect(CalendarDisplayMode.week.stepComponent == .day)
        #expect(CalendarDisplayMode.month.stepComponent == .weekOfYear)
        #expect(CalendarDisplayMode.year.stepComponent == .month)
        #expect(CalendarDisplayMode.week.component == .weekOfYear)
        #expect(CalendarDisplayMode.month.component == .month)
    }

    @Test func calendarColorsLiftInDarkAndDeepenWithIncreasedContrast() throws {
        let components = try #require(CalendarColor.components(hex: "#0b8043"))
        let light = CalendarColor.adjusted(components, dark: false, contrast: false)
        let dark = CalendarColor.adjusted(components, dark: true, contrast: false)
        let contrast = CalendarColor.adjusted(components, dark: false, contrast: true)
        #expect(dark.brightnessComponent > light.brightnessComponent)
        #expect(contrast.saturationComponent > light.saturationComponent)
        #expect(abs(dark.hueComponent - light.hueComponent) < 0.01)
        #expect(CalendarColor.components(hex: "teal") == nil)
        #expect(CalendarColor.tint(Tokens.Calendar.eventTint, contrast: .increased) == Tokens.Calendar.eventTint * 2)
        #expect(CalendarColor.tint(Tokens.Calendar.eventTint, contrast: .standard) == Tokens.Calendar.eventTint)
    }
}
