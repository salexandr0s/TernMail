import Foundation
import GmailAPI

/// Form values are compared with the event that opened the editor. Unchanged
/// fields keep their original representation, including unknown Google fields.
struct CalendarEditorValues {
    var title: String
    var location: String
    var notes: String
    var url: String
    var start: Date
    var end: Date
    var allDay: Bool
    var timeZoneID: String
    var recurrence: [String]
    var attendees: [CalendarAttendee]
    var usesDefaultAlerts: Bool
    var reminders: [CalendarReminder]

    init(event: GoogleCalendarEvent, calendar: Calendar) {
        title = event.summary ?? ""
        location = event.location ?? ""
        notes = event.description ?? ""
        url = event.rawValue["source"]?.objectValue?["url"]?.stringValue ?? ""
        start = event.start?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? .now
        let exclusiveEnd = event.end?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? start.addingTimeInterval(1800)
        end = event.isAllDay ? calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? start : exclusiveEnd
        allDay = event.isAllDay
        timeZoneID = event.start?.timeZone ?? calendar.timeZone.identifier
        recurrence = event.recurrence ?? []
        attendees = event.attendees ?? []
        usesDefaultAlerts = event.reminders?.useDefault ?? true
        reminders = event.reminders?.overrides ?? []
    }

    func applying(to original: GoogleCalendarEvent, calendar: Calendar, timeZone: TimeZone) -> GoogleCalendarEvent {
        let baseline = Self(event: original, calendar: calendar)
        var output = original
        if title != baseline.title { output.summary = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if location != baseline.location { output.location = location.isEmpty ? nil : location }
        if notes != baseline.notes { output.description = notes.isEmpty ? nil : notes }
        var civil = calendar; civil.timeZone = timeZone
        let changedDateKind = allDay != baseline.allDay || timeZoneID != baseline.timeZoneID
        if start != baseline.start || changedDateKind {
            output.start = CalendarDateTime(date: allDay ? civil.startOfDay(for: start) : start, timeZone: timeZone, allDay: allDay)
        }
        if end != baseline.end || changedDateKind {
            let exclusiveEnd = allDay ? civil.date(byAdding: .day, value: 1, to: civil.startOfDay(for: end)) ?? end : end
            output.end = CalendarDateTime(date: exclusiveEnd, timeZone: timeZone, allDay: allDay)
        }
        if recurrence != baseline.recurrence { output.recurrence = recurrence.isEmpty ? nil : recurrence }
        if attendees != baseline.attendees { output.attendees = attendees.isEmpty ? nil : attendees }
        if usesDefaultAlerts != baseline.usesDefaultAlerts || reminders != baseline.reminders {
            output.reminders = CalendarEventReminders(useDefault: usesDefaultAlerts, overrides: usesDefaultAlerts ? nil : reminders)
        }
        if url != baseline.url {
            if url.isEmpty { output.rawValue.removeValue(forKey: "source") }
            else {
                var source = output.rawValue["source"]?.objectValue ?? [:]
                source["url"] = .string(url); source["title"] = source["title"] ?? .string("Event link")
                output.rawValue["source"] = .object(source)
            }
        }
        return output
    }
}
