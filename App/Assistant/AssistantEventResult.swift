import CryptoKit
import Foundation
import GmailAPI

/// Existing events retain provider metadata. Mail candidates contain only the
/// fields needed for a personal calendar entry and remain unsaved until review.
struct AssistantEventResult: Identifiable, Sendable, Equatable {
    let source: AssistantSource
    let event: GoogleCalendarEvent
    let evidence: String?
    let uncertainties: [String]

    init(source: AssistantSource, event: GoogleCalendarEvent, evidence: String? = nil,
         uncertainties: [String] = []) {
        self.source = source
        if source.isCalendar {
            self.event = event
        } else {
            var personal = GoogleCalendarEvent(summary: event.summary)
            personal.description = event.description
            personal.location = event.location
            personal.start = event.start
            personal.end = event.end
            self.event = personal
        }
        self.evidence = evidence
        var warnings = uncertainties.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !source.isCalendar, event.start == nil { warnings.append("Date to be confirmed") }
        if !source.isCalendar, event.start != nil, event.end == nil { warnings.append("Choose an event duration.") }
        var seen = Set<String>()
        self.uncertainties = warnings.filter { seen.insert($0).inserted }
    }

    var id: String {
        if isExistingEvent { return source.id }
        let start = event.start?.date ?? event.start?.dateTime.flatMap(CalendarDateCoding.date).map(CalendarDateCoding.string) ?? ""
        let identity = [source.id, title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), start].joined(separator: "\u{0}")
        return "assistant-event:" + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var title: String {
        let value = (event.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Untitled event" : value
    }

    var isExistingEvent: Bool { source.isCalendar }

    var canAddToCalendar: Bool {
        guard !isExistingEvent, let messageID = source.messageID, !messageID.isEmpty,
              let start = event.start, let first = Self.validDate(start) else { return false }
        guard let end = event.end else { return true }
        guard start.isAllDay == end.isAllDay, let last = Self.validDate(end) else { return false }
        return last > first
    }

    var emailItem: EmailCalendarItem {
        var item = EmailCalendarItem(id: id, messageID: source.messageID ?? "", title: title,
            evidence: evidence ?? "", kind: .proposed, event: event, invitation: nil, uncertainties: uncertainties)
        if case .calendar(let calendarID, let eventID) = source.target {
            item.existingCalendarID = calendarID
            item.existingEventID = eventID
        }
        return item
    }

    func presentation(calendar: Calendar = .autoupdatingCurrent) -> EmailCalendarPresentation {
        EmailCalendarPresentation(item: emailItem, calendar: calendar)
    }

    private static func validDate(_ value: CalendarDateTime) -> Date? {
        guard value.timeZone == nil || value.timeZone.flatMap(TimeZone.init(identifier:)) != nil else { return nil }
        if value.isAllDay {
            var civil = value
            civil.timeZone = nil
            return civil.resolvedDate(fallbackTimeZone: TimeZone(secondsFromGMT: 0) ?? .current)
        }
        guard value.date == nil, let text = value.dateTime else { return nil }
        // Mail extraction must resolve a floating time before it becomes an
        // actionable event. CalendarDateCoding accepts only absolute timestamps.
        return CalendarDateCoding.date(text)
    }
}
