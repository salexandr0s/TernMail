import Foundation
import Testing
@testable import Tern

struct RecurrenceSelectionTests {
    @Test(arguments: ["Europe/Vienna", "America/Los_Angeles", "Pacific/Auckland"])
    func endDateRoundTripsInTheEventTimeZone(_ identifier: String) throws {
        let zone = try #require(TimeZone(identifier: identifier))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = try #require(calendar.date(from: DateComponents(year: 2027, month: 3, day: 28, hour: 12)))
        for allDay in [true, false] {
            var input = RecurrenceSelection(rules: [], allDay: allDay, timeZone: zone)
            input.frequency = "WEEKLY"
            input.weekdays = ["MO", "FR"]
            input.endMode = "until"
            input.until = date
            let rules = input.rules(allDay: allDay, timeZone: zone)
            let reopened = RecurrenceSelection(rules: rules, allDay: allDay, timeZone: zone)
            #expect(reopened.frequency == "WEEKLY")
            #expect(reopened.endMode == "until")
            #expect(calendar.isDate(reopened.until, inSameDayAs: date))
            #expect(reopened.rules(allDay: allDay, timeZone: zone) == rules)
        }
    }

    @Test func changingTheIntervalPreservesAnExactProviderCutoff() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var selection = RecurrenceSelection(rules: ["RRULE:FREQ=DAILY;UNTIL=20270115T120000Z"], timeZone: zone)
        #expect(selection.frequency == "DAILY")
        selection.interval = 2
        #expect(selection.rules(allDay: false, timeZone: zone) == ["RRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20270115T120000Z"])
    }

    @Test(arguments: [
        "RRULE:FREQ=WEEKLY;UNTIL=garbage",
        "RRULE:FREQ=WEEKLY;UNTIL=20270230T235959Z",
        "RRULE:FREQ=WEEKLY;COUNT=3;UNTIL=20270115T235959Z",
        "RRULE:FREQ=WEEKLY;INTERVAL=0",
        "RRULE:FREQ=WEEKLY;COUNT=2;COUNT=3",
        "RRULE:FREQ=WEEKLY;UNTIL=20270115",
    ])
    func unsupportedRulesStayCustom(_ rule: String) throws {
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let selection = RecurrenceSelection(rules: [rule], timeZone: zone)
        #expect(selection.frequency == "CUSTOM")
        #expect(selection.rules(allDay: false, timeZone: zone) == [rule])
    }
}
