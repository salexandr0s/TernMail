import Foundation
import GmailAPI
import Testing
@testable import SyncEngine

@Suite struct CalendarAvailabilityTests {
    @Test func mergesOverlappingBusyIntervalsAndAllowsTouchingBoundaries() throws {
        let start = try #require(CalendarDateCoding.date("2026-11-02T09:00:00+01:00"))
        let end = start.addingTimeInterval(3 * 3600)
        let blocks = [CalendarBusyInterval(start: start, end: start.addingTimeInterval(45 * 60)),
                      CalendarBusyInterval(start: start.addingTimeInterval(30 * 60), end: start.addingTimeInterval(90 * 60))]
        let slots = CalendarAvailability.findSlots(start: start, end: end, busy: blocks,
            hours: CalendarWorkingHours(timeZoneIdentifier: "Europe/Vienna", startMinute: 540, endMinute: 720, durationMinutes: 30, stepMinutes: 30))
        #expect(slots.map(\.start) == [start.addingTimeInterval(90 * 60), start.addingTimeInterval(120 * 60), start.addingTimeInterval(150 * 60)])
    }

    @Test func workingHoursStayLocalAcrossDaylightSaving() throws {
        let start = try #require(CalendarDateCoding.date("2026-10-23T00:00:00+02:00"))
        let end = try #require(CalendarDateCoding.date("2026-10-27T00:00:00+01:00"))
        let slots = CalendarAvailability.findSlots(start: start, end: end, busy: [],
            hours: CalendarWorkingHours(timeZoneIdentifier: "Europe/Vienna", startMinute: 540, endMinute: 570, durationMinutes: 30))
        #expect(slots.count == 2)
        #expect(slots.first?.start == CalendarDateCoding.date("2026-10-23T07:00:00Z"))
        #expect(slots.last?.start == CalendarDateCoding.date("2026-10-26T08:00:00Z"))
    }

    @Test func malformedBusyDataAndInvalidConfigurationNeverProduceSlots() throws {
        let start = try #require(CalendarDateCoding.date("2026-11-02T09:00:00+01:00"))
        let end = start.addingTimeInterval(3600)
        #expect(CalendarAvailability.findSlots(start: start, end: end, busy: [.init(start: "not a date", end: "neither")], hours: .init()).isEmpty)
        #expect(CalendarAvailability.findSlots(start: start, end: end, busy: [], hours: .init(timeZoneIdentifier: "invalid")).isEmpty)
        #expect(CalendarAvailability.findSlots(start: end, end: start, busy: [], hours: .init()).isEmpty)
    }
}
