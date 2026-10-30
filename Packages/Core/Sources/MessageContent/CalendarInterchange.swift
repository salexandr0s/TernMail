import Foundation
import GmailAPI

public struct CalendarImportGroup: Sendable, Equatable {
    public var uid: String
    public var master: Invitation?
    public var exceptions: [Invitation]
}

public enum CalendarInterchangeError: Error, LocalizedError, Sendable, Equatable {
    case missingDate, invalidDate, unresolvedTimeZone(String), recurrenceExceptionNeedsSeries
    case unsupportedAlarm, unsupportedTimeZoneExport(String)

    public var errorDescription: String? {
        switch self {
        case .missingDate: "This event needs a start and end date."
        case .invalidDate: "This event has an invalid date or duration."
        case .unresolvedTimeZone(let zone): "Review the event's time zone (\(zone)) before importing it."
        case .recurrenceExceptionNeedsSeries: "Import this occurrence together with its repeating event."
        case .unsupportedAlarm: "This event has an alert that cannot be preserved. Review its alerts before continuing."
        case .unsupportedTimeZoneExport(let zone): "The repeating event's time zone (\(zone)) cannot be exported accurately."
        }
    }
}

public enum CalendarInterchange {
    public static func importEvents(_ data: Data) throws -> [Invitation] {
        try Invitation.parseAll(data: data)
    }

    public static func importGroups(_ data: Data) throws -> [CalendarImportGroup] {
        let events = try importEvents(data)
        var order: [String] = []
        var grouped: [String: [Invitation]] = [:]
        for event in events {
            if grouped[event.uid] == nil { order.append(event.uid) }
            grouped[event.uid, default: []].append(event)
        }
        return order.map { uid in
            let values = grouped[uid] ?? []
            let master = values.filter { $0.recurrenceKey.isEmpty }.max(by: isOlder)
            let keys = Set(values.filter { !$0.recurrenceKey.isEmpty }.map(\.recurrenceKey))
            let exceptions = keys.sorted().compactMap { key in
                values.filter { $0.recurrenceKey == key }.max(by: isOlder)
            }
            return CalendarImportGroup(uid: uid, master: master, exceptions: exceptions)
        }
    }

    public static func googleEvent(from invitation: Invitation,
                                   fallbackTimeZone: TimeZone = .autoupdatingCurrent) throws -> GoogleCalendarEvent {
        guard invitation.recurrenceKey.isEmpty else { throw CalendarInterchangeError.recurrenceExceptionNeedsSeries }
        return try convert(invitation, fallbackTimeZone: fallbackTimeZone)
    }

    public static func googleException(from invitation: Invitation, parentEventID: String,
                                       fallbackTimeZone: TimeZone = .autoupdatingCurrent) throws -> GoogleCalendarEvent {
        guard !parentEventID.isEmpty, !invitation.recurrenceKey.isEmpty,
              let property = invitation.originalEvent?.property("RECURRENCE-ID") else {
            throw CalendarInterchangeError.recurrenceExceptionNeedsSeries
        }
        var event = try convert(invitation, fallbackTimeZone: fallbackTimeZone)
        var calendar = ICalendarComponent(name: "VCALENDAR", components: invitation.timeZoneDefinitions ?? [])
        calendar.components.append(ICalendarComponent(name: "VEVENT", properties: [
            ICalendarProperty("UID", value: invitation.uid),
            ICalendarProperty("DTSTART", parameters: property.parameters, value: property.value),
        ]))
        let original = try Invitation(calendar: calendar)
        guard let time = original.start else { throw CalendarInterchangeError.invalidDate }
        event.originalStartTime = try googleTime(time, repeating: false, fallback: fallbackTimeZone)
        event.recurringEventId = parentEventID
        return event
    }

    /// Retains source properties, cancellation state and custom VTIMEZONE components.
    public static func exportInvitations(_ invitations: [Invitation]) throws -> Data {
        var events: [ICalendarComponent] = []
        var zones: [String: ICalendarComponent] = [:]
        for invitation in invitations.flatMap({ [$0] + ($0.additionalEvents ?? []) }) {
            guard var component = invitation.originalEvent else { throw CalendarInterchangeError.missingDate }
            if invitation.isCancelled {
                component.properties.removeAll { $0.name == "STATUS" }
                component.properties.append(ICalendarProperty("STATUS", value: "CANCELLED"))
            }
            events.append(component)
            for zone in invitation.timeZoneDefinitions ?? [] {
                if let id = zone.property("TZID")?.value { zones[id] = zone }
            }
        }
        return serialized(events: events, zones: zones.keys.sorted().compactMap { zones[$0] })
    }

    public static func exportEvents(_ events: [GoogleCalendarEvent], now: Date = Date()) throws -> Data {
        var components: [ICalendarComponent] = []
        var zones: [String: ICalendarComponent] = [:]
        for event in events {
            var properties = [
                ICalendarProperty("UID", value: event.iCalUID ?? (event.id.isEmpty ? UUID().uuidString + "@tern" : event.id + "@google.com")),
                ICalendarProperty("DTSTAMP", value: LocalDateTime(utc: now).basicFormat + "Z"),
            ]
            if let sequence = event.sequence { properties.append(ICalendarProperty("SEQUENCE", value: String(sequence))) }
            for (name, value) in [("SUMMARY", event.summary), ("DESCRIPTION", event.description), ("LOCATION", event.location)] {
                if let value { properties.append(ICalendarProperty(name, value: ICalendar.escape(value))) }
            }
            if let start = event.start { properties.append(try exportedTime(start, name: "DTSTART", repeating: event.recurrence?.isEmpty == false, zones: &zones)) }
            if let end = event.end { properties.append(try exportedTime(end, name: "DTEND", repeating: event.recurrence?.isEmpty == false, zones: &zones)) }
            if let original = event.originalStartTime { properties.append(try exportedTime(original, name: "RECURRENCE-ID", repeating: false, zones: &zones)) }
            for line in event.recurrence ?? [] {
                guard let property = ICalendar.contentLine(Substring(line)),
                      ["RRULE", "EXRULE", "RDATE", "EXDATE"].contains(property.name) else { throw CalendarInterchangeError.invalidDate }
                if let id = property.parameter("TZID"), zones[id] == nil {
                    guard let zone = TimeZone(identifier: id) else { throw CalendarInterchangeError.unresolvedTimeZone(id) }
                    zones[id] = try ICalendarZoneExport.component(zone: zone, startingAt: event.startDate ?? now, now: now)
                }
                properties.append(property)
            }
            if let status = event.status { properties.append(ICalendarProperty("STATUS", value: status.uppercased())) }
            if let transparency = event.transparency { properties.append(ICalendarProperty("TRANSP", value: transparency.uppercased())) }
            if let visibility = event.visibility, visibility != "default" {
                properties.append(ICalendarProperty("CLASS", value: visibility.uppercased()))
            }
            if let url = event.rawValue["source"]?.objectValue?["url"]?.stringValue ?? event.htmlLink {
                properties.append(ICalendarProperty("URL", value: url))
            }
            if let organizer = event.rawValue["organizer"]?.objectValue,
               let email = organizer["email"]?.stringValue {
                properties.append(ICalendarProperty("ORGANIZER", value: "mailto:" + email))
            }
            for attendee in event.attendees ?? [] {
                var parameters: [ICalendarProperty.Parameter] = []
                if let name = attendee.displayName { parameters.append(.init("CN", value: name)) }
                if let status = attendee.responseStatus {
                    let partstat = status == "needsAction" ? "NEEDS-ACTION" : status.uppercased()
                    parameters.append(.init("PARTSTAT", value: partstat))
                }
                if attendee.optional == true { parameters.append(.init("ROLE", value: "OPT-PARTICIPANT")) }
                properties.append(ICalendarProperty("ATTENDEE", parameters: parameters, value: "mailto:" + attendee.email))
            }
            let alarms = try (event.reminders?.overrides ?? []).map { reminder in
                guard (0...40_320).contains(reminder.minutes), ["email", "popup"].contains(reminder.method) else {
                    throw CalendarInterchangeError.unsupportedAlarm
                }
                var properties = [
                    ICalendarProperty("ACTION", value: reminder.method == "email" ? "EMAIL" : "DISPLAY"),
                    ICalendarProperty("TRIGGER", value: "-PT\(reminder.minutes)M"),
                    ICalendarProperty("DESCRIPTION", value: ICalendar.escape(event.summary ?? "Event")),
                ]
                if reminder.method == "email" {
                    let recipient = event.attendees?.first(where: { $0.isSelf == true })?.email
                        ?? (event.organizer?.isSelf == true ? event.organizer?.email : nil)
                    guard let recipient else { throw CalendarInterchangeError.unsupportedAlarm }
                    properties.append(ICalendarProperty("SUMMARY", value: ICalendar.escape(event.summary ?? "Event")))
                    properties.append(ICalendarProperty("ATTENDEE", value: "mailto:" + recipient))
                }
                return ICalendarComponent(name: "VALARM", properties: properties)
            }
            components.append(ICalendarComponent(name: "VEVENT", properties: properties, components: alarms))
        }
        return serialized(events: components, zones: zones.keys.sorted().compactMap { zones[$0] })
    }

    private static func convert(_ invitation: Invitation, fallbackTimeZone: TimeZone) throws -> GoogleCalendarEvent {
        var result = GoogleCalendarEvent(summary: invitation.summary)
        result.iCalUID = invitation.uid
        result.description = invitation.notes
        result.location = invitation.location
        result.status = invitation.isCancelled ? "cancelled" : "confirmed"
        result.sequence = invitation.sequence
        result.recurrence = invitation.recurrenceLines?.isEmpty == false ? invitation.recurrenceLines : nil
        if let start = invitation.start, let end = invitation.end {
            result.start = try googleTime(start, repeating: invitation.repeats, fallback: fallbackTimeZone)
            result.end = try googleTime(end, repeating: invitation.repeats, fallback: fallbackTimeZone)
        } else if !invitation.isCancelled { throw CalendarInterchangeError.missingDate }
        if let start = result.start?.resolvedDate(fallbackTimeZone: fallbackTimeZone),
           let end = result.end?.resolvedDate(fallbackTimeZone: fallbackTimeZone), end < start {
            throw CalendarInterchangeError.invalidDate
        }
        result.attendees = invitation.attendees.compactMap { attendee in
            guard let email = attendee.email else { return nil }
            let status: String = switch attendee.status {
            case .accepted: "accepted"
            case .declined: "declined"
            case .tentative: "tentative"
            case .needsAction, .delegated: "needsAction"
            }
            return CalendarAttendee(email: email, displayName: attendee.name, responseStatus: status)
        }
        if let organizer = invitation.organizer?.email {
            result.rawValue["organizer"] = .object(["email": .string(organizer)])
        }
        if let url = invitation.url, let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), ["https", "http"].contains(scheme) {
            result.rawValue["source"] = .object(["url": .string(url), "title": .string(invitation.summary ?? "Event")])
        }
        var reminders: [CalendarReminder] = []
        for alarm in invitation.alarms ?? [] {
            let seconds = alarm.relativeSeconds ?? alarm.absoluteDate.flatMap { date in
                result.start?.resolvedDate(fallbackTimeZone: fallbackTimeZone).map { Int(date.timeIntervalSince($0)) }
            }
            guard ["DISPLAY", "EMAIL"].contains(alarm.action), !alarm.relatesToEnd,
                  let seconds, seconds <= 0, seconds % 60 == 0, -seconds / 60 <= 40_320 else {
                throw CalendarInterchangeError.unsupportedAlarm
            }
            reminders.append(CalendarReminder(method: alarm.action == "EMAIL" ? "email" : "popup", minutes: -seconds / 60))
        }
        guard reminders.count <= 5 else { throw CalendarInterchangeError.unsupportedAlarm }
        result.reminders = CalendarEventReminders(useDefault: false, overrides: reminders)
        return result
    }

    private static func googleTime(_ time: EventTime, repeating: Bool, fallback: TimeZone) throws -> CalendarDateTime {
        switch time {
        case .allDay(let day): return CalendarDateTime(date: String(format: "%04d-%02d-%02d", day.year, day.month, day.day))
        case .utc(let date): return CalendarDateTime(date: date, timeZone: TimeZone(secondsFromGMT: 0) ?? fallback)
        case .zoned(let date, let zone, _):
            if let resolved = TimeZone(identifier: zone) { return CalendarDateTime(date: date, timeZone: resolved) }
            guard !repeating else { throw CalendarInterchangeError.unresolvedTimeZone(zone) }
            return CalendarDateTime(date: date, timeZone: TimeZone(secondsFromGMT: 0) ?? fallback)
        case .floating(let local):
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = fallback
            let parts = DateComponents(year: local.day.year, month: local.day.month, day: local.day.day,
                                       hour: local.hour, minute: local.minute, second: local.second)
            guard let date = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == parts else {
                throw CalendarInterchangeError.invalidDate
            }
            return CalendarDateTime(date: date, timeZone: fallback)
        case .unresolved(_, let zone): throw CalendarInterchangeError.unresolvedTimeZone(zone)
        }
    }

    private static func exportedTime(_ time: CalendarDateTime, name: String, repeating: Bool,
                                     zones: inout [String: ICalendarComponent]) throws -> ICalendarProperty {
        if let date = time.date {
            guard time.dateTime == nil, time.resolvedDate() != nil else { throw CalendarInterchangeError.invalidDate }
            return ICalendarProperty(name, parameters: [.init("VALUE", value: "DATE")], value: date.replacingOccurrences(of: "-", with: ""))
        }
        guard let date = time.resolvedDate() else { throw CalendarInterchangeError.invalidDate }
        if repeating, let id = time.timeZone, let zone = TimeZone(identifier: id),
           zone.secondsFromGMT(for: date) != 0 || zone.nextDaylightSavingTimeTransition(after: date) != nil {
            if zones[id] == nil { zones[id] = try ICalendarZoneExport.component(zone: zone, startingAt: date) }
            let local = LocalDateTime(epochSeconds: Int(date.timeIntervalSince1970) + zone.secondsFromGMT(for: date))
            return ICalendarProperty(name, parameters: [.init("TZID", value: id)], value: local.basicFormat)
        }
        return ICalendarProperty(name, value: LocalDateTime(utc: date).basicFormat + "Z")
    }

    private static func serialized(events: [ICalendarComponent], zones: [ICalendarComponent]) -> Data {
        Data(ICalendarComponent(name: "VCALENDAR", properties: [
            ICalendarProperty("VERSION", value: "2.0"),
            ICalendarProperty("PRODID", value: InvitationReply.productID),
            ICalendarProperty("CALSCALE", value: "GREGORIAN"),
        ], components: zones + events).serialized().utf8)
    }

    private static func isOlder(_ lhs: Invitation, _ rhs: Invitation) -> Bool {
        (lhs.sequence, lhs.stamp ?? .distantPast) < (rhs.sequence, rhs.stamp ?? .distantPast)
    }
}
