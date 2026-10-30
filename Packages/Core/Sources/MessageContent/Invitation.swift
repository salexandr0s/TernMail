import Foundation
import GmailAPI

/// A calendar invitation, update, cancellation or reply read from an iTIP
/// message (RFC 5546).
public struct Invitation: Codable, Sendable, Equatable {
    public enum Method: Codable, Sendable, Equatable {
        case request
        case cancel
        case reply
        case other(String)

        init(_ value: String) {
            switch value.trimmingCharacters(in: .whitespaces).uppercased() {
            case "REQUEST": self = .request
            case "CANCEL": self = .cancel
            case "REPLY": self = .reply
            case let other: self = .other(other)
            }
        }
    }

    public enum ParticipationStatus: String, Codable, Sendable {
        case needsAction = "NEEDS-ACTION"
        case accepted = "ACCEPTED"
        case declined = "DECLINED"
        case tentative = "TENTATIVE"
        case delegated = "DELEGATED"
    }

    public struct Participant: Codable, Sendable, Equatable {
        /// The calendar address exactly as written, usually `mailto:…`.
        /// Organizers match a reply's attendee by this value, so replies copy it.
        public var calendarAddress: String
        /// The address without `mailto:`. Nil for other kinds of address.
        public var email: String?
        public var name: String?
        public var status: ParticipationStatus
        public var rsvp: Bool

        init(_ property: ICalendarProperty) {
            calendarAddress = property.value.trimmingCharacters(in: .whitespaces)
            email = Self.email(in: calendarAddress)
            name = property.parameter("CN")?.trimmingCharacters(in: .whitespaces).nonEmpty
            // RFC 5545 reads an unknown status as NEEDS-ACTION.
            status = property.parameter("PARTSTAT").flatMap { ParticipationStatus(rawValue: $0.uppercased()) } ?? .needsAction
            rsvp = property.parameter("RSVP")?.uppercased() == "TRUE"
        }

        /// Whether this is `address`, ignoring case.
        public func matches(_ address: String) -> Bool {
            guard let email else { return false }
            return email.caseInsensitiveCompare(address.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }

        private static func email(in calendarAddress: String) -> String? {
            let address: String
            if calendarAddress.lowercased().hasPrefix("mailto:") {
                let rest = String(calendarAddress.dropFirst("mailto:".count))
                address = rest.removingPercentEncoding ?? rest
            } else if !calendarAddress.contains(":") {
                address = calendarAddress
            } else {
                return nil
            }
            let trimmed = address.trimmingCharacters(in: .whitespaces)
            return trimmed.contains("@") ? trimmed : nil
        }
    }

    /// What a REPLY copies from the request.
    struct ReplySource: Codable, Sendable, Equatable {
        var organizer: ICalendarProperty?
        var recurrenceID: ICalendarProperty?
        /// The VTIMEZONE that `recurrenceID`'s TZID needs.
        var timeZone: ICalendarComponent?
    }

    /// Nil when the object has no METHOD, as in a plain calendar export.
    public var method: Method?
    /// As written, since organizers match replies by it.
    public var uid: String
    /// Empty for the whole event. For one occurrence, its RECURRENCE-ID in
    /// UTC when the zone resolves, otherwise as written.
    public var recurrenceKey: String
    public var sequence: Int
    public var stamp: Date?
    public var summary: String?
    public var location: String?
    public var start: EventTime?
    /// Exclusive for all-day events; `lastDay` is the one to show.
    public var end: EventTime?
    public var repeats: Bool
    public var isCancelled: Bool
    public var organizer: Participant?
    public var attendees: [Participant]
    var replySource: ReplySource

    public init(data: Data, charset: String? = nil) throws {
        try self.init(calendar: ICalendar.parse(data, charset: charset))
    }

    /// Reads the master VEVENT, or the first one when every VEVENT is a
    /// single occurrence.
    public init(calendar: ICalendarComponent) throws {
        guard calendar.name == "VCALENDAR" else { throw ICalendarError.noCalendar }
        let events = calendar.components(named: "VEVENT")
        guard let event = events.first(where: { $0.property("RECURRENCE-ID") == nil }) ?? events.first else {
            throw ICalendarError.noEvent
        }
        guard let uid = event.property("UID")?.value.trimmingCharacters(in: .whitespaces), !uid.isEmpty else {
            throw ICalendarError.missingUID
        }
        let resolver = TimeZoneResolver(calendar)

        method = calendar.property("METHOD").map { Method($0.value) }
        self.uid = uid
        sequence = event.property("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) }.map { max(0, $0) } ?? 0
        stamp = event.property("DTSTAMP").flatMap(ICalendarTime.init).flatMap { resolver.resolve($0).date }
        summary = event.property("SUMMARY")?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        location = event.property("LOCATION")?.text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        repeats = event.property("RRULE") != nil || event.property("RDATE") != nil
        isCancelled = method == .cancel || event.property("STATUS")?.value.trimmingCharacters(in: .whitespaces).uppercased() == "CANCELLED"
        organizer = event.property("ORGANIZER").map(Participant.init)
        attendees = event.properties(named: "ATTENDEE").map(Participant.init)

        let startTime = event.property("DTSTART").flatMap(ICalendarTime.init)
        start = startTime.map(resolver.resolve)
        if let endTime = event.property("DTEND").flatMap(ICalendarTime.init) {
            end = resolver.resolve(endTime)
        } else if let startTime {
            // RFC 5545: DURATION when DTEND is missing; with neither, a
            // date-time event ends when it starts and a date event lasts a day.
            let duration = event.property("DURATION").flatMap { ICalendarDuration($0.value) }
                ?? (startTime.zone == .date ? ICalendarDuration(days: 1) : ICalendarDuration())
            end = resolver.resolve(startTime, adding: duration)
        } else {
            end = nil
        }

        replySource = ReplySource(organizer: event.property("ORGANIZER"))
        recurrenceKey = ""
        if let recurrenceID = event.property("RECURRENCE-ID") {
            (recurrenceKey, replySource.recurrenceID, replySource.timeZone) = Self.recurrence(recurrenceID, resolver: resolver)
        }
    }

    /// The key, the property a reply carries and the VTIMEZONE it needs.
    private static func recurrence(
        _ property: ICalendarProperty,
        resolver: TimeZoneResolver
    ) -> (String, ICalendarProperty?, ICalendarComponent?) {
        let asWritten = property.value.trimmingCharacters(in: .whitespaces)
        guard let time = ICalendarTime(property) else { return (asWritten, property, nil) }
        guard case .named(let tzid) = time.zone else {
            return (time.zone == .utc ? time.local.basicFormat + "Z" : asWritten, property, nil)
        }
        let utc = resolver.resolve(time).date.map { LocalDateTime(utc: $0).basicFormat + "Z" }
        if let definition = resolver.definition(for: tzid) {
            return (utc ?? asWritten, property, definition)
        }
        guard let utc else { return (asWritten, property, nil) }
        // RFC 5545 needs a VTIMEZONE for every TZID, and the request had none.
        let converted = ICalendarProperty(
            "RECURRENCE-ID",
            parameters: property.parameters.filter { $0.name != "TZID" && $0.name != "VALUE" },
            value: utc
        )
        return (utc, converted, nil)
    }

    /// The last day of an all-day event, since DTEND is the day after.
    public var lastDay: CalendarDay? {
        guard case .allDay(let first) = start else { return nil }
        guard case .allDay(let end) = end, end > first else { return first }
        return end.adding(days: -1)
    }

    /// The first attendee whose address is one of `addresses`, ignoring case.
    public func attendee(matchingAnyOf addresses: some Sequence<String>) -> Participant? {
        let addresses = Array(addresses)
        return attendees.first { attendee in addresses.contains(where: attendee.matches) }
    }
}

/// Where an invitation's calendar data sits in a `full`-format payload.
public struct CalendarPart: Sendable, Equatable {
    public var partID: String?
    /// Nil when Gmail put the bytes in the payload.
    public var attachmentID: String?
    public var size: Int
    /// An attached file counts only when it has a METHOD, since a plain
    /// calendar export isn't an invitation.
    public var isAttachment: Bool
    var inlineData: Data?
    var charset: String?
}

public enum CalendarParts {
    /// Bounds calendar downloads to four parts reported at most 1 MiB each.
    public static let maximumAttachmentDownloads = 4

    /// Candidates in the order they're tried: `text/calendar` parts outside
    /// attachments, then attached `text/calendar`, `application/ics` and
    /// `.ics` files. Attached messages aren't searched.
    public static func candidates(in message: GmailMessage) -> [CalendarPart] {
        guard let payload = message.payload else { return [] }
        var inline: [CalendarPart] = []
        var attached: [CalendarPart] = []
        collect(payload, inline: &inline, attached: &attached)
        return inline + attached
    }

    /// The next eligible candidate in priority order, stopping when a known
    /// candidate parses. Record each attempt before fetching, then call again
    /// with its bytes. Failed attempts count toward the per-message limit.
    public static func requiredAttachmentID(
        of message: GmailMessage,
        attachments: [String: Data] = [:],
        attemptedAttachmentIDs: Set<String> = []
    ) -> String? {
        guard attemptedAttachmentIDs.count < maximumAttachmentDownloads else { return nil }
        for candidate in candidates(in: message) where isWithinSizeLimit(candidate) {
            if let data = data(for: candidate, attachments: attachments) {
                if invitation(from: candidate, data: data) != nil { return nil }
                continue
            }
            if let id = candidate.attachmentID, !attemptedAttachmentIDs.contains(id) { return id }
        }
        return nil
    }

    /// The invitation from the first candidate that parses. `attachments`
    /// maps attachment IDs to downloaded bytes.
    public static func invitation(in message: GmailMessage, attachments: [String: Data] = [:]) -> Invitation? {
        for candidate in candidates(in: message) {
            guard let data = data(for: candidate, attachments: attachments),
                  let invitation = invitation(from: candidate, data: data) else { continue }
            return invitation
        }
        return nil
    }

    private static func isWithinSizeLimit(_ candidate: CalendarPart) -> Bool {
        (0...ICalendar.maxSize).contains(candidate.size)
    }

    private static func data(for candidate: CalendarPart, attachments: [String: Data]) -> Data? {
        candidate.inlineData ?? candidate.attachmentID.flatMap { attachments[$0] }
    }

    private static func invitation(from candidate: CalendarPart, data: Data) -> Invitation? {
        guard isWithinSizeLimit(candidate), data.count <= ICalendar.maxSize,
              let invitation = try? Invitation(data: data, charset: candidate.charset),
              !candidate.isAttachment || invitation.method != nil else { return nil }
        return invitation
    }

    private static func collect(_ part: MessagePart, inline: inout [CalendarPart], attached: inout [CalendarPart]) {
        let mimeType = (part.mimeType ?? "").lowercased()
        if mimeType == "message/rfc822" { return }
        let isFile = MIMEParts.isAttachment(part)
        if mimeType.hasPrefix("multipart/") {
            guard !isFile else { return }
            for child in part.parts ?? [] { collect(child, inline: &inline, attached: &attached) }
            return
        }
        let isCalendar = mimeType == "text/calendar"
            || (isFile && (mimeType == "application/ics" || (part.filename ?? "").lowercased().hasSuffix(".ics")))
        guard isCalendar else { return }
        let found = CalendarPart(
            partID: part.partId,
            attachmentID: part.body?.attachmentId,
            size: part.body?.size ?? 0,
            isAttachment: isFile,
            inlineData: part.body?.decodedData,
            charset: part.header("Content-Type").flatMap { MIMEReader.parameters(of: $0)["charset"] }
        )
        if isFile { attached.append(found) } else { inline.append(found) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
