import Foundation
import GmailAPI
import Testing
@testable import SyncEngine

@Suite struct CalendarRecurrencePartitionTests {
    @Test func partitionsDateListsWithoutReformattingTheirValues() throws {
        let value = try partition([
            "RRULE:FREQ=WEEKLY",
            "EXDATE;TZID=Europe/Vienna:20261026T100000,20261109T100000",
            "RDATE:20261028T090000Z,20261111T090000Z",
        ], start: "2026-10-26T10:00:00+01:00", split: "2026-11-02T10:00:00+01:00")
        #expect(value.before == ["RRULE:FREQ=WEEKLY;UNTIL=20261102T085959Z",
            "EXDATE;TZID=Europe/Vienna:20261026T100000", "RDATE:20261028T090000Z"])
        #expect(value.following == ["RRULE:FREQ=WEEKLY", "EXDATE;TZID=Europe/Vienna:20261109T100000", "RDATE:20261111T090000Z"])
    }

    @Test func countIncludesExcludedNominalDatesAndIgnoresAddedDates() throws {
        let value = try partition(["RRULE:FREQ=DAILY;COUNT=5", "EXDATE;TZID=Europe/Vienna:20261103T100000",
                                   "RDATE;TZID=Europe/Vienna:20261102T120000"],
                                  start: "2026-11-02T10:00:00+01:00", split: "2026-11-04T10:00:00+01:00")
        #expect(value.following == ["RRULE:FREQ=DAILY;COUNT=3"])
        #expect(value.before == ["RRULE:FREQ=DAILY;UNTIL=20261104T085959Z", "EXDATE;TZID=Europe/Vienna:20261103T100000",
                                 "RDATE;TZID=Europe/Vienna:20261102T120000"])
    }

    @Test func allDayCountAndDateListsSurviveTheDaylightSavingBoundary() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let value = try CalendarRecurrencePartition(lines: ["RRULE:FREQ=DAILY;COUNT=5", "EXDATE;VALUE=DATE:20261024,20261027",
            "RDATE;VALUE=DATE:20261023,20261030"], start: .init(date: "2026-10-23"), split: .init(date: "2026-10-25"), timeZone: zone)
        #expect(value.before == ["RRULE:FREQ=DAILY;UNTIL=20261024", "EXDATE;VALUE=DATE:20261024", "RDATE;VALUE=DATE:20261023"])
        #expect(value.following == ["RRULE:FREQ=DAILY;COUNT=3", "EXDATE;VALUE=DATE:20261027", "RDATE;VALUE=DATE:20261030"])
    }

    @Test func intervalWeeklyCountUsesWeekStartAndNominalWeekdays() throws {
        let value = try partition(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=MO;COUNT=8", "EXDATE:20261104T090000Z"],
            start: "2026-11-02T10:00:00+01:00", split: "2026-11-16T10:00:00+01:00")
        #expect(value.following == ["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;WKST=MO;COUNT=6"])
    }

    @Test func monthlyOrdinalAndSetPositionCountCandidatesBeforeExclusions() throws {
        let ordinal = try partition(["RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=5", "EXDATE:20261127T090000Z"],
            start: "2026-10-30T10:00:00+01:00", split: "2026-12-25T10:00:00+01:00")
        #expect(ordinal.following == ["RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3"])
        let positioned = try partition(["RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=5"],
            start: "2026-10-30T10:00:00+01:00", split: "2026-12-31T10:00:00+01:00")
        #expect(positioned.following == ["RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1;COUNT=3"])
    }

    @Test func yearlyLeapDaysAndNonexistentLocalTimesDoNotConsumeCount() throws {
        let leap = try partition(["RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;COUNT=4"],
            start: "2024-02-29T10:00:00+01:00", split: "2028-02-29T10:00:00+01:00")
        #expect(leap.following == ["RRULE:FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=29;COUNT=3"])
        let gap = try partition(["RRULE:FREQ=DAILY;COUNT=5"],
            start: "2026-03-28T02:30:00+01:00", split: "2026-03-30T02:30:00+02:00")
        #expect(gap.following == ["RRULE:FREQ=DAILY;COUNT=4"])
    }

    @Test func splittingAfterTheRuleEndedDoesNotExtendIt() throws {
        let counted = try partition(["RRULE:FREQ=DAILY;COUNT=2", "RDATE:20261109T090000Z,20261110T090000Z"],
            start: "2026-11-02T10:00:00+01:00", split: "2026-11-09T10:00:00+01:00")
        #expect(counted.before == ["RRULE:FREQ=DAILY;COUNT=2"])
        #expect(counted.following == ["RDATE:20261109T090000Z,20261110T090000Z"])
        let until = try partition(["RRULE:FREQ=DAILY;UNTIL=20261103T090000Z", "RDATE:20261109T090000Z"],
            start: "2026-11-02T10:00:00+01:00", split: "2026-11-09T10:00:00+01:00", preservingSchedule: false)
        #expect(until.before == ["RRULE:FREQ=DAILY;UNTIL=20261103T090000Z"])
    }

    @Test func unsupportedOrAmbiguousRulesFailBeforeMutation() throws {
        for lines in [
            ["RRULE:FREQ=WEEKLY", "RRULE:FREQ=MONTHLY"],
            ["RRULE:FREQ=WEEKLY", "EXRULE:FREQ=YEARLY"],
            ["RRULE:FREQ=WEEKLY", "RDATE;VALUE=PERIOD:20261103T100000Z/PT1H"],
            ["RRULE:FREQ=DAILY;BYHOUR=10,12;COUNT=5"],
            ["RRULE:FREQ=WEEKLY", "EXDATE;TZID=Unknown/Zone:20261103T100000"],
            ["RRULE:FREQ=WEEKLY;INTERVAL=2", "RDATE:20261103T090000Z"],
        ] {
            #expect(throws: CalendarEngineError.self) {
                try partition(lines, start: "2026-11-02T10:00:00+01:00", split: "2026-11-03T10:00:00+01:00")
            }
        }
    }

    private func partition(_ lines: [String], start: String, split: String, preservingSchedule: Bool = true) throws -> CalendarRecurrencePartition {
        let zone = try #require(TimeZone(identifier: "Europe/Vienna"))
        return try CalendarRecurrencePartition(lines: lines, start: .init(dateTime: start, timeZone: zone.identifier),
            split: .init(dateTime: split, timeZone: zone.identifier), timeZone: zone, preservingSchedule: preservingSchedule)
    }
}
