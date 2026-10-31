import Foundation
import MessageContent

/// Handoff for what the window shows. Tern on another Mac continues an
/// activity; other devices open its web page in Gmail or Google Calendar.
/// Activities are never offered to search.
enum MailUserActivity {
    /// The conversation in the active reader.
    static let conversationType = "dev.tern.mail.conversation"
    /// The day the calendar shows.
    static let calendarDayType = "dev.tern.calendar.day"
    private static let linkKey = "link"
    private static let dayKey = "day"

    /// Describes the conversation `link` names. `email` is its account's
    /// address, which selects the mailbox in Gmail on the web.
    static func describeConversation(_ activity: NSUserActivity, link: MailLink, subject: String, email: String?) {
        activity.title = subject.isEmpty ? "No Subject" : subject
        activity.webpageURL = email.flatMap { link.gmailURL(email: $0) }
        activity.userInfo = link.ternURL.map { [linkKey: $0.absoluteString] } ?? [:]
        offerForHandoffOnly(activity)
    }

    /// The `tern://` link a continued conversation carries.
    static func conversationLink(in activity: NSUserActivity) -> URL? {
        (activity.userInfo?[linkKey] as? String).flatMap { URL(string: $0) }
    }

    /// Describes the day that contains `date` in `calendar`.
    static func describeCalendarDay(_ activity: NSUserActivity, date: Date, calendar: Calendar, title: String) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return }
        activity.title = title
        activity.webpageURL = URL(string: "https://calendar.google.com/calendar/r/day/\(year)/\(month)/\(day)")
        activity.userInfo = [dayKey: "\(year)-\(month)-\(day)"]
        offerForHandoffOnly(activity)
    }

    /// The start of a continued day in `calendar`.
    static func calendarDay(in activity: NSUserActivity, calendar: Calendar) -> Date? {
        guard let value = activity.userInfo?[dayKey] as? String else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func offerForHandoffOnly(_ activity: NSUserActivity) {
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
    }
}
