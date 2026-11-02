import AppKit
import Foundation
import GmailAPI
import SwiftUI
import Testing
@testable import Tern

@Suite struct CalendarLayoutTests {
    @MainActor @Test func miniMonthMarkersCountOvernightEventsAndKeepAllDayEndsExclusive() throws {
        let calendar = try calendar("Europe/Vienna")
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25)))
        let next = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        let allDay = CalendarDisplayEvent(event: GoogleCalendarEvent(id: "away", summary: "Away",
            start: CalendarDateTime(date: "2026-10-25"), end: CalendarDateTime(date: "2026-10-26")),
            accountID: "account", calendarID: "calendar", colorHex: "#FF0000", fallbackTimeZoneID: "Europe/Vienna")
        let overnight = event("overnight", start: next.addingTimeInterval(-1800), end: next.addingTimeInterval(1800))
        let duplicateColor = event("same-calendar", start: day, end: day.addingTimeInterval(3600))
        let activity = CalendarMiniMonth.activity(events: [allDay, overnight, duplicateColor],
            days: CalendarLayout.monthDays(containing: day, calendar: calendar), calendar: calendar)

        #expect(activity[day]?.count == 3)
        #expect(activity[day]?.colors == ["#ff0000", "#4285f4"])
        #expect(activity[next]?.count == 1)
        #expect(activity[next]?.colors == ["#4285f4"])
    }

    @Test func monthDragFindsDaysAcrossWeekRowsAndRejectsOutsideCanvas() {
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 699, y: 99), width: 700, rowHeight: 100) == 6)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 0, y: 100), width: 700, rowHeight: 100) == 7)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 699, y: 599), width: 700, rowHeight: 100) == 41)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 700, y: 50), width: 700, rowHeight: 100) == nil)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 10, y: -1), width: 700, rowHeight: 100) == nil)
        #expect(CalendarMonthHitTesting.index(at: CGPoint(x: 10, y: 600), width: 700, rowHeight: 100) == nil)
    }

    /// A 2026 day when the clocks change, and the clock hour it skips or repeats.
    struct Transition: Sendable {
        var zone: String
        var month: Int
        var day: Int
        var hour: Int
        var repeats: Bool
    }

    static let transitions = [
        Transition(zone: "Europe/Berlin", month: 3, day: 29, hour: 2, repeats: false),
        Transition(zone: "Europe/Berlin", month: 10, day: 25, hour: 2, repeats: true),
        Transition(zone: "America/New_York", month: 3, day: 8, hour: 2, repeats: false),
        Transition(zone: "America/New_York", month: 11, day: 1, hour: 1, repeats: true),
    ]

    private func calendar(_ zone: String = "Europe/Vienna") throws -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = try #require(TimeZone(identifier: zone))
        value.firstWeekday = 2
        return value
    }

    private func event(_ id: String, start: Date, end: Date) -> CalendarDisplayEvent {
        CalendarDisplayEvent(event: GoogleCalendarEvent(id: id, summary: id,
            start: CalendarDateTime(date: start), end: CalendarDateTime(date: end)),
            accountID: "account", calendarID: "calendar")
    }

    /// An ordinary week has eight rows above 8 AM. A day that skips or repeats an
    /// earlier hour has one fewer or one more.
    @MainActor @Test(arguments: [(zone: "Europe/Vienna", month: 10, day: 30, isWeek: true, rowsAbove: 8),
                                 (zone: "Europe/Berlin", month: 3, day: 29, isWeek: false, rowsAbove: 7),
                                 (zone: "America/New_York", month: 11, day: 1, isWeek: false, rowsAbove: 9)])
    func timeGridOpensAtEightInTheMorning(_ opening: (zone: String, month: Int, day: Int, isWeek: Bool, rowsAbove: Int)) async throws {
        let calendar = try calendar(opening.zone)
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: opening.month, day: opening.day)))
        let grid = CalendarTimeGrid(date: day, isWeek: opening.isWeek, calendar: calendar, events: [], selectedID: .constant(nil),
                                    create: { _ in }, edit: { _ in }, change: { _, _ in }, delete: { _ in },
                                    duplicate: { _ in }, dropMail: { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: grid)
        window.orderFront(nil)
        defer { window.close() }
        let expected = Tokens.Space.s2 + CGFloat(opening.rowsAbove) * grid.hourHeight
        var offset: CGFloat?
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            // The hours scroll inside the horizontal day scroller; only they are taller than the window.
            offset = scrollViews(in: window.contentView).first { ($0.documentView?.frame.height ?? 0) > 12 * grid.hourHeight }?
                .contentView.bounds.origin.y
        } while offset.map({ abs($0 - expected) >= 1 }) ?? true && ContinuousClock.now < deadline
        #expect(abs(try #require(offset) - expected) < 1)
    }

    @MainActor private func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    @Test func overlappingEventsReceiveIndependentLanesAndLaterEventsRecoverWidth() throws {
        let calendar = try calendar()
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 30)))
        let a = event("a", start: CalendarLayout.date(at: 540, on: day, calendar: calendar), end: CalendarLayout.date(at: 600, on: day, calendar: calendar))
        let b = event("b", start: CalendarLayout.date(at: 570, on: day, calendar: calendar), end: CalendarLayout.date(at: 660, on: day, calendar: calendar))
        let c = event("c", start: CalendarLayout.date(at: 660, on: day, calendar: calendar), end: CalendarLayout.date(at: 720, on: day, calendar: calendar))
        let result = CalendarTimelinePlacement.layout([c, b, a], day: day, axis: CalendarTimeAxis(days: [day], calendar: calendar))
        #expect(result.map(\.lane) == [0, 1, 0])
        #expect(result.map(\.lanes) == [2, 2, 1])
    }

    @Test(arguments: CalendarLayoutTests.transitions)
    func transitionDayShowsItsRealHoursAndPlacesEventsByRealTime(_ transition: Transition) throws {
        let calendar = try calendar(transition.zone)
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: transition.month, day: transition.day)))
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: day))
        let axis = CalendarTimeAxis(days: [day], calendar: calendar)
        var hours = Array(0..<24)
        if transition.repeats { hours.insert(transition.hour, at: transition.hour) } else { hours.remove(at: transition.hour) }
        #expect(axis.rows.map(\.hour) == hours)
        #expect(midnight.timeIntervalSince(day) == Double(hours.count * 3600))
        // Each row starts a real hour after the one above and is labeled with the clock hour then.
        for (index, row) in axis.rows.enumerated() {
            let start = day.addingTimeInterval(Double(index * 3600))
            #expect(axis.rowDates[index] == start)
            #expect(calendar.component(.hour, from: start) == row.hour)
            #expect(axis.date(atMinute: Double(index * 60), on: day) == start)
            #expect(axis.minute(of: start.addingTimeInterval(1800), on: day) == Double(index * 60 + 30))
        }
        #expect(axis.date(atMinute: Double(axis.minuteCount), on: day, allowEndOfDay: true) == midnight)
        #expect(axis.date(atMinute: Double(axis.minuteCount), on: day) == midnight.addingTimeInterval(-900))
        // An event across the change is as tall as it is long.
        let change = day.addingTimeInterval(Double((transition.repeats ? transition.hour + 1 : transition.hour) * 3600))
        let across = CalendarTimelinePlacement.layout([event("across", start: change.addingTimeInterval(-1800), end: change.addingTimeInterval(1800))],
                                                      day: day, axis: axis)
        #expect(across.map(\.startMinute) == [Int(change.timeIntervalSince(day) / 60) - 30])
        #expect(across.map(\.endMinute) == [Int(change.timeIntervalSince(day) / 60) + 30])
        guard transition.repeats else { return }
        // The same clock times in both passes of the repeated hour no longer overlap.
        let first = event("first", start: change.addingTimeInterval(-2700), end: change.addingTimeInterval(-900))
        let second = event("second", start: change.addingTimeInterval(900), end: change.addingTimeInterval(2700))
        #expect(calendar.dateComponents([.hour, .minute], from: first.start) == calendar.dateComponents([.hour, .minute], from: second.start))
        let passes = CalendarTimelinePlacement.layout([first, second], day: day, axis: axis)
        #expect(passes.map(\.lanes) == [1, 1])
        #expect(passes.map(\.startMinute) == [transition.hour * 60 + 15, (transition.hour + 1) * 60 + 15])
    }

    @Test(arguments: CalendarLayoutTests.transitions)
    func transitionWeekAlignsClockTimesAndAMissingRowTakesNoTime(_ transition: Transition) throws {
        let calendar = try calendar(transition.zone)
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: transition.month, day: transition.day)))
        let previous = try #require(calendar.date(byAdding: .day, value: -1, to: day))
        let axis = CalendarTimeAxis(days: [previous, day], calendar: calendar)
        #expect(axis.rows.count == (transition.repeats ? 25 : 24))
        // The hour after the change sits at the same height in both columns.
        let after = [previous, day].compactMap { calendar.date(bySettingHour: transition.hour + 1, minute: 0, second: 0, of: $0) }
        try #require(after.count == 2)
        let row = Double(axis.row(ofHour: transition.hour + 1) * 60)
        #expect(zip([previous, day], after).map { axis.minute(of: $1, on: $0) } == [row, row])
        // A row one day lacks takes no time there: every point in it is that day's next hour.
        let missing = transition.repeats ? transition.hour + 1 : transition.hour
        let lacking = transition.repeats ? previous : day
        #expect(!axis.has(row: missing, on: lacking))
        #expect(axis.has(row: missing, on: transition.repeats ? day : previous))
        #expect(axis.date(atMinute: Double(missing * 60 + 30), on: lacking, snapped: false) == after[transition.repeats ? 0 : 1])
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
        let snapshot = CalendarPresentationSnapshot(events: [event],
            interval: DateInterval(start: first, end: after.addingTimeInterval(86_400)), calendar: calendar, buildsTimeAxis: true)
        #expect(snapshot.day(first)?.allDay.map(\.id) == [event.id])
        #expect(snapshot.day(last)?.allDay.map(\.id) == [event.id])
        #expect(snapshot.day(after) == nil)
        #expect(snapshot.timeAxis?.rows.count == 25)
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
