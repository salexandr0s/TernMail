import Foundation
import GmailAPI

/// The tile and its date line share one calendar and time zone. Date-only values
/// are civil dates; they must never shift when viewed in another time zone.
struct EmailCalendarPresentation {
    struct Status {
        let text: String
        let symbol: String
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
        guard let start else { return "Date to be confirmed" }
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

    var status: Status? {
        if item.isOutdated { return Status(text: "Replaced by a newer invitation", symbol: "clock.arrow.circlepath") }
        if item.kind == .cancelled { return Status(text: "Cancelled", symbol: "calendar.badge.minus") }
        if item.hasAmbiguousMatch { return Status(text: "Several calendar matches · Check details", symbol: "exclamationmark.circle") }
        if item.kind == .updated { return Status(text: "Updated in this conversation", symbol: "arrow.triangle.2.circlepath") }
        if !item.uncertainties.isEmpty { return Status(text: "Details need review", symbol: "info.circle") }
        if item.existingEventID != nil { return Status(text: "On your calendar", symbol: "checkmark.circle") }
        return nil
    }

    var location: String? {
        let value = (item.event?.location ?? item.invitation?.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
