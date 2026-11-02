import Foundation
import GmailAPI
import SwiftUI

struct CalendarRecoveryEventDetails: View {
    let title: String
    let event: GoogleCalendarEvent
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(event.title).font(.headline)
            if let start = event.start?.resolvedDate(fallbackTimeZone: calendar.timeZone),
               let end = event.end?.resolvedDate(fallbackTimeZone: calendar.timeZone) {
                Text(dateRange(start: start, end: end)).font(.callout)
                Text(event.isAllDay ? "All day" : calendar.timeZone.identifier).font(.caption).foregroundStyle(.secondary)
            }
            if let location = event.location, !location.isEmpty { Text(location).font(.callout) }
            if let description = event.description, !description.isEmpty { Text(description).font(.callout) }
            if let recurrence = event.recurrence, !recurrence.isEmpty {
                CalendarRecurrenceDescription(rules: recurrence, allDay: event.isAllDay, calendar: calendar)
            }
            Text("\(event.transparency == "transparent" ? "Free" : "Busy") · \(visibility)").font(.caption)
            if let reminders = event.reminders {
                if reminders.useDefault == true { Text("Calendar's default alerts").font(.caption) }
                else if reminders.overrides?.isEmpty != false { Text("No alerts").font(.caption) }
                else {
                    ForEach(Array((reminders.overrides ?? []).enumerated()), id: \.offset) { _, reminder in
                        Text("\(reminder.method == "email" ? "Email" : "Notification") \(reminder.minutes) minutes before").font(.caption)
                    }
                }
            }
            if let link = event.hangoutLink ?? event.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri,
               let url = safeURL(link) {
                Link(destination: url) { Label("Join Meeting", systemImage: "video") }
                    .accessibilityLabel("Join meeting: \(event.title)")
            }
            if let link = event.htmlLink, let url = safeURL(link) {
                Link("Open in Google Calendar", destination: url)
                    .accessibilityLabel("Open \(event.title) in Google Calendar")
            }
            ForEach(event.attendees ?? [], id: \.email) { attendee in
                Text("\(attendee.displayName ?? attendee.email) · \(attendee.email) · \(response(attendee.responseStatus))")
                    .font(.caption)
            }
            ForEach(event.attachments ?? []) { attachment in
                if let url = safeURL(attachment.fileUrl) {
                    Link(attachment.title ?? "Open Attachment", destination: url).font(.caption)
                }
            }
        }
        .textSelection(.enabled)
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
    }

    private var visibility: String {
        switch event.visibility {
        case "private": "Private"
        case "public": "Public"
        default: "Calendar's default visibility"
        }
    }

    private func response(_ value: String?) -> String {
        switch value {
        case "accepted": "Accepted"
        case "declined": "Declined"
        case "tentative": "Tentative"
        default: "Needs reply"
        }
    }

    private func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func dateRange(start: Date, end: Date) -> String {
        if event.isAllDay {
            let last = calendar.date(byAdding: .day, value: -1, to: end) ?? start
            let first = CalendarLayout.format(start, style: .dateTime.year().month().day(), calendar: calendar)
            if calendar.isDate(start, inSameDayAs: last) { return first }
            return first + " – " + CalendarLayout.format(last, style: .dateTime.year().month().day(), calendar: calendar)
        }
        return CalendarLayout.format(start, style: .dateTime.year().month().day().hour().minute(), calendar: calendar)
            + " – " + CalendarLayout.format(end, style: .dateTime.year().month().day().hour().minute(), calendar: calendar)
    }
}
