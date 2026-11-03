import Foundation
import GmailAPI
import MessageContent
import SwiftUI
import Testing
@testable import Tern

@Suite @MainActor struct DesignAccessibilityTests {
    @Test func readingEnlargementPreservesExistingValuesAndReachesTwoHundredPercent() {
        for scale in [0.85, 1, 1.15, 1.25, 1.3, 1.5, 1.75, 2] {
            #expect(ReadingPreferences.textScale(scale) == scale)
        }
        #expect(ReadingPreferences.textScale(2.5) == 2)
        #expect(ReadingPreferences.textScale(.infinity) == 1)
        let page = MessageDocument.render(plainText: "Reading enlargement", policy: .init(textScale: ReadingPreferences.textScale(2)))
        #expect(page.html.contains("font-size:26.0px"))
    }

    @Test func calendarIdentityUsesAccountScopedKeysAndDisambiguatesRepeatedTitles() {
        let work = CalendarDisplayCalendar(entry: .init(id: "primary", summary: "Meetings"), accountID: "work", accountName: "Work")
        let personal = CalendarDisplayCalendar(entry: .init(id: "primary", summary: "Meetings"), accountID: "personal", accountName: "Personal")
        let shared = CalendarDisplayCalendar(entry: .init(id: "shared", summary: "Team"), accountID: "work", accountName: "Work")
        let identities = CalendarIdentityPresentation(calendars: [work, personal, shared])
        #expect(identities.title(for: work.id) == "Meetings (Work)")
        #expect(identities.title(for: personal.id) == "Meetings (Personal)")
        #expect(identities.title(for: shared.id) == "Team")
        #expect(identities == CalendarIdentityPresentation(calendars: [shared, personal, work]))
    }

    @Test func isolatedCalendarViewsHaveAStableReadableFallback() {
        let environment = EnvironmentValues()
        #expect(environment.calendarIdentities.title(for: "unavailable") == "Calendar")
        #expect(environment.calendarIdentities == CalendarIdentityPresentation(calendars: []))
    }

    @Test func allDayEventDescriptionsUseIncludedDatesAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        for (month, startDay, endDay, includedLastDay) in [(11, 3, 4, 3), (11, 3, 6, 5), (3, 28, 30, 29), (10, 24, 26, 25)] {
            let start = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: startDay)))
            let end = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: endDay)))
            let includedLast = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: includedLastDay)))
            let firstText = CalendarLayout.format(start, style: .dateTime.month(.wide).day().year(), calendar: calendar)
            let lastText = CalendarLayout.format(includedLast, style: .dateTime.month(.wide).day().year(), calendar: calendar)
            #expect(CalendarEventDateDescription.text(start: start, end: end, isAllDay: true, calendar: calendar)
                == (startDay == includedLastDay ? firstText : "\(firstText) – \(lastText)"))
        }
    }

    @Test func timedEventDescriptionsRetainBothExactEndpoints() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 23, minute: 30)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 4, minute: 15)))
        let style: Date.FormatStyle = .dateTime.month(.wide).day().year().hour().minute()
        #expect(CalendarEventDateDescription.text(start: start, end: end, isAllDay: false, calendar: calendar)
            == "\(CalendarLayout.format(start, style: style, calendar: calendar)) – \(CalendarLayout.format(end, style: style, calendar: calendar))")
    }
}
