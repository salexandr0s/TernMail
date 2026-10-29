import Foundation

/// An emailed iTIP REPLY (RFC 5546, RFC 6047) to an invitation.
public enum InvitationReply {
    public enum Answer: String, Sendable, CaseIterable {
        case accepted = "ACCEPTED"
        case tentative = "TENTATIVE"
        case declined = "DECLINED"
    }

    public static let productID = "-//Tern//Tern Mail//EN"

    /// The subject, also used as the plain text part: "Accepted: Team sync".
    public static func subject(for answer: Answer, summary: String?) -> String {
        let verb = switch answer {
        case .accepted: "Accepted"
        case .tentative: "Tentatively accepted"
        case .declined: "Declined"
        }
        guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return verb }
        return verb + ": " + summary
    }

    /// The body for `text/calendar; method=REPLY; charset=UTF-8`. One VEVENT
    /// with the request's UID, RECURRENCE-ID, SEQUENCE and ORGANIZER, and
    /// `attendee` with `answer`. A REPLY needs no DTSTART, DTEND or VALARM.
    public static func calendar(
        replyingTo invitation: Invitation,
        as attendee: Invitation.Participant,
        answer: Answer,
        now: Date = Date()
    ) -> String {
        var event = ICalendarComponent(name: "VEVENT", properties: [ICalendarProperty("UID", value: invitation.uid)])
        if let recurrenceID = invitation.replySource.recurrenceID { event.properties.append(recurrenceID) }
        event.properties += [
            ICalendarProperty("SEQUENCE", value: String(invitation.sequence)),
            ICalendarProperty("DTSTAMP", value: LocalDateTime(utc: now).basicFormat + "Z"),
        ]
        if let organizer = invitation.replySource.organizer { event.properties.append(organizer) }
        if let summary = invitation.summary { event.properties.append(ICalendarProperty("SUMMARY", value: ICalendar.escape(summary))) }

        // RSVP asks for a reply, so a reply leaves it out.
        var parameters = [ICalendarProperty.Parameter("PARTSTAT", value: answer.rawValue)]
        if let name = attendee.name { parameters.append(.init("CN", value: name)) }
        event.properties.append(ICalendarProperty("ATTENDEE", parameters: parameters, value: attendee.calendarAddress))

        let calendar = ICalendarComponent(
            name: "VCALENDAR",
            properties: [
                ICalendarProperty("VERSION", value: "2.0"),
                ICalendarProperty("PRODID", value: productID),
                ICalendarProperty("METHOD", value: "REPLY"),
            ],
            components: (invitation.replySource.timeZone.map { [$0] } ?? []) + [event]
        )
        return calendar.serialized()
    }
}
