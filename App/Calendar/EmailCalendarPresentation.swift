import Foundation
import GmailAPI
import MessageContent

/// The tile and its date line share one calendar and time zone. Date-only values
/// are civil dates; they must never shift when viewed in another time zone.
struct EmailCalendarPresentation {
    enum BadgeTone: Equatable { case positive, caution, negative, neutral }

    struct Badge: Equatable {
        let text: String
        let symbol: String
        let tone: BadgeTone
    }

    let item: EmailCalendarItem
    let calendar: Calendar

    private var locale: Locale {
        guard let locale = calendar.locale, !locale.identifier.isEmpty else { return .autoupdatingCurrent }
        return locale
    }

    var title: String {
        let value = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Untitled event" : value
    }

    var start: Date? { resolve(item.event?.start) }

    var inclusiveEnd: Date? {
        guard let start, let end = resolve(item.event?.end), end > start else { return nil }
        if item.event?.isAllDay == true {
            return calendar.date(byAdding: .day, value: -1, to: end)
        }
        return end
    }

    var month: String? { start.map { format($0, .dateTime.month(.abbreviated)).uppercased(with: locale) } }
    var day: String? { start.map { format($0, .dateTime.day()) } }

    var dateLine: String {
        guard let start else { return originalTimeZoneLine ?? "Date to be confirmed" }
        let dateStyle = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        let firstDate = format(start, dateStyle)
        if item.event?.isAllDay == true {
            if let end = inclusiveEnd, !calendar.isDate(start, inSameDayAs: end) {
                return "\(firstDate) – \(format(end, dateStyle)) · All day"
            }
            return "\(firstDate) · All day"
        }
        let timeStyle = Date.FormatStyle.dateTime.hour().minute()
        let firstTime = format(start, timeStyle)
        let zone = calendar.timeZone.abbreviation(for: start) ?? calendar.timeZone.identifier
        guard let end = inclusiveEnd else { return "\(firstDate) · \(firstTime) \(zone)" }
        let endZone = calendar.timeZone.abbreviation(for: end) ?? calendar.timeZone.identifier
        if calendar.isDate(start, inSameDayAs: end) {
            let startZone = zone == endZone ? "" : " \(zone)"
            return "\(firstDate) · \(firstTime)\(startZone)–\(format(end, timeStyle)) \(endZone)"
        }
        return "\(firstDate), \(firstTime) \(zone) – \(format(end, dateStyle)), \(format(end, timeStyle)) \(endZone)"
    }

    /// A tick means a saved event or an explicit acceptance, never just a
    /// detected date. Warnings take precedence over an earlier acceptance.
    var badge: Badge {
        if item.isOutdated {
            return Badge(text: "Replaced by a newer invitation", symbol: "clock.arrow.circlepath", tone: .neutral)
        }
        if item.kind == .cancelled { return Badge(text: "Cancelled", symbol: "xmark", tone: .negative) }
        if item.hasAmbiguousMatch {
            return Badge(text: "Several calendar matches. Review details.", symbol: "questionmark", tone: .caution)
        }
        if let warning = item.authenticityWarning {
            return Badge(text: warning, symbol: "questionmark", tone: .caution)
        }
        if !item.uncertainties.isEmpty {
            return Badge(text: "Review event details", symbol: "questionmark", tone: .caution)
        }
        if item.kind == .updated {
            return Badge(text: "Updated in this conversation", symbol: "arrow.triangle.2.circlepath", tone: .neutral)
        }
        if item.kind == .response { return responseBadge }
        if item.existingEventID == nil, item.kind == .detected || item.kind == .proposed {
            return Badge(text: "Event suggestion. Review before adding.", symbol: "questionmark", tone: .caution)
        }
        if let answer = item.previousAnswer ?? item.calendarAnswer, let answerLine {
            return Self.badge(for: answer, text: answerLine)
        }
        if start == nil { return Badge(text: "Date to be confirmed", symbol: "questionmark", tone: .caution) }
        if item.existingEventID != nil {
            return Badge(text: "On your calendar", symbol: "checkmark", tone: .positive)
        }
        return Badge(text: "Invitation to review", symbol: "questionmark", tone: .caution)
    }

    private var responseBadge: Badge {
        let attendees = item.invitation?.attendees ?? []
        guard let answer = attendees.first?.status else {
            return Badge(text: "Attendee response needs review", symbol: "questionmark", tone: .caution)
        }
        guard attendees.allSatisfy({ $0.status == answer }) else {
            return Badge(text: "Mixed attendee responses", symbol: "questionmark", tone: .caution)
        }
        let text = attendees.count == 1 ? responseLines[0]
            : "\(attendees.count) attendees: \(Self.answerText(answer))"
        return Self.badge(for: answer, text: text)
    }

    private static func badge(for answer: Invitation.ParticipationStatus, text: String) -> Badge {
        switch answer {
        case .accepted: Badge(text: text, symbol: "checkmark", tone: .positive)
        case .declined: Badge(text: text, symbol: "xmark", tone: .negative)
        case .tentative, .needsAction: Badge(text: text, symbol: "questionmark", tone: .caution)
        case .delegated: Badge(text: text, symbol: "arrow.turn.up.right", tone: .neutral)
        }
    }

    var answerLine: String? {
        if let answer = item.previousAnswer { return "Last email response: \(Self.answerText(answer))" }
        if let answer = item.calendarAnswer { return "Your response: \(Self.answerText(answer))" }
        return nil
    }

    var location: String? {
        let value = (item.event?.location ?? item.invitation?.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var organizer: String? {
        guard let person = item.invitation?.organizer else { return nil }
        return person.email.map { EmailAddress(name: person.name, address: $0).displayString } ?? person.name
    }

    var responseLines: [String] {
        guard item.kind == .response else { return [] }
        return item.invitation?.attendees.map {
            let name = $0.name ?? $0.email ?? $0.calendarAddress
            return "\(name): \(Self.answerText($0.status))"
        } ?? []
    }

    var recurrenceNote: String? {
        guard let invitation = item.invitation else { return nil }
        if !invitation.recurrenceKey.isEmpty { return "This occurrence of a repeating event" }
        return invitation.repeats ? "Repeats" : nil
    }

    var originalTimeZoneLine: String? {
        guard let time = item.invitation?.start else { return nil }
        let date: Date
        let zone: TimeZone
        let name: String
        switch time {
        case .zoned(let value, let identifier, let offset):
            guard identifier != calendar.timeZone.identifier, let fixed = TimeZone(secondsFromGMT: offset) else { return nil }
            date = value; zone = fixed; name = identifier
        case .utc(let value):
            guard calendar.timeZone.secondsFromGMT(for: value) != 0, let utc = TimeZone(secondsFromGMT: 0) else { return nil }
            date = value; zone = utc; name = "UTC"
        case .unresolved(let local, let identifier):
            guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
            var civil = Calendar(identifier: .gregorian)
            civil.timeZone = utc
            guard let value = civil.date(from: DateComponents(year: local.day.year, month: local.day.month,
                day: local.day.day, hour: local.hour, minute: local.minute, second: local.second)) else { return nil }
            date = value; zone = utc; name = "\(identifier) · Time zone unrecognized"
        case .allDay, .floating: return nil
        }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().year().hour().minute()
        style.calendar = calendar; style.timeZone = zone; style.locale = locale
        return "\(date.formatted(style)) \(name)"
    }

    private static func answerText(_ answer: Invitation.ParticipationStatus) -> String {
        switch answer {
        case .accepted: "Accepted"
        case .declined: "Declined"
        case .tentative: "Maybe"
        case .needsAction: "Not answered"
        case .delegated: "Delegated"
        }
    }

    static func ordered(_ items: [EmailCalendarItem], messages: [EmailCalendarMessage]) -> [EmailCalendarItem] {
        let dates = messages.reduce(into: [String: Date]()) { $0[$1.id] = $1.date }
        return items.enumerated().sorted { lhs, rhs in
            let leftPriority = priority(lhs.element), rightPriority = priority(rhs.element)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftDate = dates[lhs.element.messageID] ?? .distantPast
            let rightDate = dates[rhs.element.messageID] ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func priority(_ item: EmailCalendarItem) -> Int {
        if item.isOutdated { return 2 }
        if item.kind == .cancelled || item.kind == .updated || item.hasAmbiguousMatch { return 0 }
        return 1
    }

    private func resolve(_ value: CalendarDateTime?) -> Date? {
        guard var value else { return nil }
        // Google date-only events are calendar dates, even if a cached payload
        // also carries a timeZone field. The reader's calendar owns formatting.
        if value.isAllDay { value.timeZone = nil }
        return value.resolvedDate(fallbackTimeZone: calendar.timeZone)
    }

    private func format(_ date: Date, _ style: Date.FormatStyle) -> String {
        var style = style
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }
}
