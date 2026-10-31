import Foundation
import MessageContent
import Testing
@testable import Tern

@Suite struct MailUserActivityTests {
    @Test func aConversationActivityCarriesItsLinksAndStaysOutOfSearch() {
        let activity = NSUserActivity(activityType: MailUserActivity.conversationType)
        let link = MailLink(accountID: "account-1", threadID: "thread-1")
        MailUserActivity.describeConversation(activity, link: link, subject: "Quarterly plan", email: "me@example.com")
        #expect(activity.title == "Quarterly plan")
        #expect(activity.webpageURL == link.gmailURL(email: "me@example.com"))
        #expect(MailUserActivity.conversationLink(in: activity) == link.ternURL)
        #expect(activity.isEligibleForHandoff)
        #expect(!activity.isEligibleForSearch)
        #expect(!activity.isEligibleForPublicIndexing)
    }

    @Test func aCalendarDayContinuesOnTheSameDayInAnotherTimeZone() throws {
        var shownIn = Calendar(identifier: .gregorian)
        shownIn.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let shown = try #require(shownIn.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23)))
        let activity = NSUserActivity(activityType: MailUserActivity.calendarDayType)
        MailUserActivity.describeCalendarDay(activity, date: shown, calendar: shownIn, title: "March 8, 2026")
        #expect(activity.webpageURL?.absoluteString == "https://calendar.google.com/calendar/r/day/2026/3/8")
        var continuedIn = Calendar(identifier: .gregorian)
        continuedIn.timeZone = try #require(TimeZone(identifier: "Europe/Athens"))
        let continued = try #require(MailUserActivity.calendarDay(in: activity, calendar: continuedIn))
        #expect(continuedIn.dateComponents([.year, .month, .day], from: continued) == DateComponents(year: 2026, month: 3, day: 8))
    }
}
