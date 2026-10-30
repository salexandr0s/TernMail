import Foundation

/// Calendar responses contain provider fields that an older editor must retain.
public enum CalendarJSON: Codable, Sendable, Equatable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([CalendarJSON]), object([String: CalendarJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([CalendarJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: CalendarJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var objectValue: [String: CalendarJSON]? { if case .object(let value) = self { value } else { nil } }

    public static func encoding(_ value: some Encodable) throws -> CalendarJSON {
        try JSONDecoder().decode(CalendarJSON.self, from: JSONEncoder().encode(value))
    }

    public func decoded<Value: Decodable>(as type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

/// A lossless resource representation. Typed properties below edit only their own field.
public protocol CalendarResource: Codable, Sendable, Equatable {
    var rawValue: [String: CalendarJSON] { get set }
    init(rawValue: [String: CalendarJSON])
}

extension CalendarResource {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try [String: CalendarJSON](from: decoder))
    }

    public func encode(to encoder: any Encoder) throws { try rawValue.encode(to: encoder) }

    func value<Value: Decodable>(_ key: String, as type: Value.Type = Value.self) -> Value? {
        guard let json = rawValue[key] else { return nil }
        return try? json.decoded(as: type)
    }

    mutating func set<Value: Encodable>(_ key: String, _ value: Value?) {
        guard let value else { rawValue.removeValue(forKey: key); return }
        // Resource property types consist only of JSON-compatible values.
        if let json = try? CalendarJSON.encoding(value) { rawValue[key] = json }
    }
}

public enum CalendarDateCoding {
    public static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    public static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public struct CalendarDateTime: Codable, Sendable, Equatable, Hashable {
    public var date: String?
    public var dateTime: String?
    public var timeZone: String?

    public init(date: String? = nil, dateTime: String? = nil, timeZone: String? = nil) {
        self.date = date; self.dateTime = dateTime; self.timeZone = timeZone
    }

    public init(date: Date, timeZone: TimeZone = .autoupdatingCurrent, allDay: Bool = false) {
        self.timeZone = allDay ? nil : timeZone.identifier
        if allDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            self.date = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
            dateTime = nil
        } else {
            self.date = nil
            dateTime = CalendarDateCoding.string(date)
        }
    }

    public var isAllDay: Bool { date != nil && dateTime == nil }

    public func resolvedDate(fallbackTimeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        guard date == nil || dateTime == nil else { return nil }
        if let dateTime {
            if let absolute = CalendarDateCoding.date(dateTime) { return absolute }
            // Google also accepts a local date-time when an IANA zone is supplied.
            guard let timeZone, let zone = TimeZone(identifier: timeZone) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.isLenient = false
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            guard let local = formatter.date(from: dateTime), formatter.string(from: local) == dateTime else { return nil }
            return local
        }
        guard let date else { return nil }
        let pieces = date.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? fallbackTimeZone
        let components = DateComponents(year: year, month: month, day: day)
        guard let result = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: result) == components else { return nil }
        return result
    }
}

public struct CalendarReminder: Codable, Sendable, Equatable, Hashable {
    public var method: String
    public var minutes: Int
    public init(method: String = "popup", minutes: Int) { self.method = method; self.minutes = minutes }
}

public struct CalendarEventReminders: Codable, Sendable, Equatable, Hashable {
    public var useDefault: Bool
    public var overrides: [CalendarReminder]?
    public init(useDefault: Bool = true, overrides: [CalendarReminder]? = nil) {
        self.useDefault = useDefault; self.overrides = overrides
    }
}

public struct CalendarAttendee: CalendarResource, Hashable {
    public var rawValue: [String: CalendarJSON]
    public init(rawValue: [String: CalendarJSON]) { self.rawValue = rawValue }
    public init(email: String, displayName: String? = nil, responseStatus: String? = nil, optional: Bool? = nil) {
        rawValue = ["email": .string(email)]
        self.displayName = displayName; self.responseStatus = responseStatus; self.optional = optional
    }
    public var email: String { get { value("email") ?? "" } set { set("email", newValue) } }
    public var displayName: String? { get { value("displayName") } set { set("displayName", newValue) } }
    public var responseStatus: String? { get { value("responseStatus") } set { set("responseStatus", newValue) } }
    public var optional: Bool? { get { value("optional") } set { set("optional", newValue) } }
    public var isSelf: Bool? { get { value("self") } set { set("self", newValue) } }
    public var organizer: Bool? { get { value("organizer") } set { set("organizer", newValue) } }
    public var comment: String? { get { value("comment") } set { set("comment", newValue) } }
    public var resource: Bool? { get { value("resource") } set { set("resource", newValue) } }
}

public struct CalendarPerson: Codable, Sendable, Equatable, Hashable {
    public var email: String?
    public var displayName: String?
    public var isSelf: Bool?
    enum CodingKeys: String, CodingKey { case email, displayName; case isSelf = "self" }
    public init(email: String? = nil, displayName: String? = nil, isSelf: Bool? = nil) {
        self.email = email; self.displayName = displayName; self.isSelf = isSelf
    }
}

public struct CalendarAttachment: CalendarResource, Hashable, Identifiable {
    public var rawValue: [String: CalendarJSON]
    public init(rawValue: [String: CalendarJSON]) { self.rawValue = rawValue }
    public init(fileUrl: String, title: String? = nil) {
        rawValue = ["fileUrl": .string(fileUrl)]; self.title = title
    }
    public var fileUrl: String { get { value("fileUrl") ?? "" } set { set("fileUrl", newValue) } }
    public var title: String? { get { value("title") } set { set("title", newValue) } }
    public var mimeType: String? { get { value("mimeType") } set { set("mimeType", newValue) } }
    public var fileId: String? { get { value("fileId") } set { set("fileId", newValue) } }
    public var iconLink: String? { get { value("iconLink") } set { set("iconLink", newValue) } }
    public var id: String { fileId ?? fileUrl }
}

public struct CalendarConferenceData: CalendarResource, Hashable {
    public var rawValue: [String: CalendarJSON]
    public init(rawValue: [String: CalendarJSON] = [:]) { self.rawValue = rawValue }
    public static func googleMeet(requestID: String) -> Self {
        Self(rawValue: ["createRequest": .object([
            "requestId": .string(requestID),
            "conferenceSolutionKey": .object(["type": .string("hangoutsMeet")]),
        ])])
    }
    public var conferenceId: String? { get { value("conferenceId") } set { set("conferenceId", newValue) } }
    public var entryPoints: [CalendarConferenceEntryPoint]? { get { value("entryPoints") } set { set("entryPoints", newValue) } }
    public var statusCode: String? {
        rawValue["createRequest"]?.objectValue?["status"]?.objectValue?["statusCode"]?.stringValue
    }
}

public struct CalendarConferenceEntryPoint: Codable, Sendable, Equatable, Hashable {
    public var entryPointType: String?
    public var uri: String?
    public var label: String?
    public var pin: String?
    public init(entryPointType: String? = nil, uri: String? = nil, label: String? = nil, pin: String? = nil) {
        self.entryPointType = entryPointType; self.uri = uri; self.label = label; self.pin = pin
    }
}

public struct CalendarExtendedProperties: Codable, Sendable, Equatable, Hashable {
    public var privateProperties: [String: String]?
    public var shared: [String: String]?
    enum CodingKeys: String, CodingKey { case privateProperties = "private"; case shared }
    public init(privateProperties: [String: String]? = nil, shared: [String: String]? = nil) {
        self.privateProperties = privateProperties; self.shared = shared
    }
}

public struct GoogleCalendarEntry: CalendarResource, Identifiable, Hashable {
    public var rawValue: [String: CalendarJSON]
    public init(rawValue: [String: CalendarJSON]) { self.rawValue = rawValue }
    public init(id: String, summary: String? = nil, timeZone: String? = nil,
                accessRole: String? = nil, backgroundColor: String? = nil) {
        rawValue = ["id": .string(id)]
        self.summary = summary; self.timeZone = timeZone; self.accessRole = accessRole; self.backgroundColor = backgroundColor
    }
    public var id: String { get { value("id") ?? "" } set { set("id", newValue) } }
    public var summary: String? { get { value("summary") } set { set("summary", newValue) } }
    public var summaryOverride: String? { get { value("summaryOverride") } set { set("summaryOverride", newValue) } }
    public var description: String? { get { value("description") } set { set("description", newValue) } }
    public var timeZone: String? { get { value("timeZone") } set { set("timeZone", newValue) } }
    public var accessRole: String? { get { value("accessRole") } set { set("accessRole", newValue) } }
    public var backgroundColor: String? { get { value("backgroundColor") } set { set("backgroundColor", newValue) } }
    public var foregroundColor: String? { get { value("foregroundColor") } set { set("foregroundColor", newValue) } }
    public var colorId: String? { get { value("colorId") } set { set("colorId", newValue) } }
    public var etag: String? { get { value("etag") } set { set("etag", newValue) } }
    public var selected: Bool? { get { value("selected") } set { set("selected", newValue) } }
    public var hidden: Bool? { get { value("hidden") } set { set("hidden", newValue) } }
    public var primary: Bool? { get { value("primary") } set { set("primary", newValue) } }
    public var deleted: Bool? { get { value("deleted") } set { set("deleted", newValue) } }
    public var defaultReminders: [CalendarReminder]? { get { value("defaultReminders") } set { set("defaultReminders", newValue) } }
    public var title: String { summaryOverride ?? summary ?? id }
    public var isOwner: Bool { accessRole == "owner" }
    public var canWrite: Bool { ["owner", "writer", "writerWithoutPrivateAccess"].contains(accessRole ?? "") && deleted != true }
    public var canReadDetails: Bool { ["owner", "writer", "writerWithoutPrivateAccess", "reader"].contains(accessRole ?? "") && deleted != true }
    public var supportsGoogleMeet: Bool {
        guard case .array(let values)? = rawValue["conferenceProperties"]?.objectValue?["allowedConferenceSolutionTypes"] else { return false }
        return values.contains(.string("hangoutsMeet"))
    }
}

public struct GoogleCalendarEvent: CalendarResource, Identifiable, Hashable {
    public var rawValue: [String: CalendarJSON]
    public init(rawValue: [String: CalendarJSON]) { self.rawValue = rawValue }
    public init(id: String = "", summary: String? = nil, start: CalendarDateTime? = nil, end: CalendarDateTime? = nil) {
        rawValue = [:]
        if !id.isEmpty { self.id = id }
        self.summary = summary; self.start = start; self.end = end
    }
    public var id: String { get { value("id") ?? "" } set { set("id", newValue) } }
    public var summary: String? { get { value("summary") } set { set("summary", newValue) } }
    public var description: String? { get { value("description") } set { set("description", newValue) } }
    public var location: String? { get { value("location") } set { set("location", newValue) } }
    public var status: String? { get { value("status") } set { set("status", newValue) } }
    public var etag: String? { get { value("etag") } set { set("etag", newValue) } }
    public var iCalUID: String? { get { value("iCalUID") } set { set("iCalUID", newValue) } }
    public var recurringEventId: String? { get { value("recurringEventId") } set { set("recurringEventId", newValue) } }
    public var htmlLink: String? { get { value("htmlLink") } set { set("htmlLink", newValue) } }
    public var hangoutLink: String? { get { value("hangoutLink") } set { set("hangoutLink", newValue) } }
    public var transparency: String? { get { value("transparency") } set { set("transparency", newValue) } }
    public var visibility: String? { get { value("visibility") } set { set("visibility", newValue) } }
    public var eventType: String? { get { value("eventType") } set { set("eventType", newValue) } }
    public var created: String? { get { value("created") } set { set("created", newValue) } }
    public var updated: String? { get { value("updated") } set { set("updated", newValue) } }
    public var colorId: String? { get { value("colorId") } set { set("colorId", newValue) } }
    public var sequence: Int? { get { value("sequence") } set { set("sequence", newValue) } }
    public var start: CalendarDateTime? { get { value("start") } set { set("start", newValue) } }
    public var end: CalendarDateTime? { get { value("end") } set { set("end", newValue) } }
    public var originalStartTime: CalendarDateTime? { get { value("originalStartTime") } set { set("originalStartTime", newValue) } }
    public var recurrence: [String]? { get { value("recurrence") } set { set("recurrence", newValue) } }
    public var attendees: [CalendarAttendee]? { get { value("attendees") } set { set("attendees", newValue) } }
    public var attendeesOmitted: Bool? { get { value("attendeesOmitted") } set { set("attendeesOmitted", newValue) } }
    public var organizer: CalendarPerson? { get { value("organizer") } set { set("organizer", newValue) } }
    public var creator: CalendarPerson? { get { value("creator") } set { set("creator", newValue) } }
    public var reminders: CalendarEventReminders? { get { value("reminders") } set { set("reminders", newValue) } }
    public var conferenceData: CalendarConferenceData? { get { value("conferenceData") } set { set("conferenceData", newValue) } }
    public var attachments: [CalendarAttachment]? { get { value("attachments") } set { set("attachments", newValue) } }
    public var extendedProperties: CalendarExtendedProperties? { get { value("extendedProperties") } set { set("extendedProperties", newValue) } }
    public var guestsCanModify: Bool? { get { value("guestsCanModify") } set { set("guestsCanModify", newValue) } }
    public var guestsCanInviteOthers: Bool? { get { value("guestsCanInviteOthers") } set { set("guestsCanInviteOthers", newValue) } }
    public var guestsCanSeeOtherGuests: Bool? { get { value("guestsCanSeeOtherGuests") } set { set("guestsCanSeeOtherGuests", newValue) } }
    public var title: String { summary?.isEmpty == false ? summary ?? "Untitled event" : "Untitled event" }
    public var startDate: Date? { start?.resolvedDate() }
    public var endDate: Date? { end?.resolvedDate() }
    public var isAllDay: Bool { start?.isAllDay == true }
    public var isCancelled: Bool { status == "cancelled" }
    public var isDeclined: Bool { attendees?.contains { $0.isSelf == true && $0.responseStatus == "declined" } == true }

    /// Only changed fields go into a PATCH; removing a field requires JSON null.
    public func changedFields(from previous: GoogleCalendarEvent) -> [String: CalendarJSON] {
        let readOnly: Set<String> = ["kind", "etag", "id", "created", "updated", "htmlLink", "creator", "organizer", "iCalUID", "recurringEventId", "originalStartTime", "hangoutLink", "locked", "privateCopy"]
        let keys = Set(rawValue.keys).union(previous.rawValue.keys).subtracting(readOnly)
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            rawValue[key] == previous.rawValue[key] ? nil : (key, rawValue[key] ?? .null)
        })
    }

    public var writableFields: [String: CalendarJSON] {
        let readOnly: Set<String> = ["kind", "etag", "created", "updated", "htmlLink", "creator", "organizer", "recurringEventId", "originalStartTime", "hangoutLink", "locked", "privateCopy"]
        return rawValue.filter { !readOnly.contains($0.key) }
    }
}

public struct CalendarListPage: Codable, Sendable, Equatable {
    public var items: [GoogleCalendarEntry]
    public var nextPageToken: String?
    public var nextSyncToken: String?
    public init(items: [GoogleCalendarEntry] = [], nextPageToken: String? = nil, nextSyncToken: String? = nil) {
        self.items = items; self.nextPageToken = nextPageToken; self.nextSyncToken = nextSyncToken
    }
    enum CodingKeys: String, CodingKey { case items, nextPageToken, nextSyncToken }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([GoogleCalendarEntry].self, forKey: .items) ?? []
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
        nextSyncToken = try c.decodeIfPresent(String.self, forKey: .nextSyncToken)
    }
}

public struct CalendarEventPage: Codable, Sendable, Equatable {
    public var items: [GoogleCalendarEvent]
    public var nextPageToken: String?
    public var nextSyncToken: String?
    public var timeZone: String?
    public var accessRole: String?
    public init(items: [GoogleCalendarEvent] = [], nextPageToken: String? = nil, nextSyncToken: String? = nil,
                timeZone: String? = nil, accessRole: String? = nil) {
        self.items = items; self.nextPageToken = nextPageToken; self.nextSyncToken = nextSyncToken
        self.timeZone = timeZone; self.accessRole = accessRole
    }
    enum CodingKeys: String, CodingKey { case items, nextPageToken, nextSyncToken, timeZone, accessRole }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([GoogleCalendarEvent].self, forKey: .items) ?? []
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
        nextSyncToken = try c.decodeIfPresent(String.self, forKey: .nextSyncToken)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        accessRole = try c.decodeIfPresent(String.self, forKey: .accessRole)
    }
}

public struct CalendarAPIErrorDetail: Codable, Sendable, Equatable {
    public var domain: String?
    public var reason: String?
    public init(domain: String? = nil, reason: String? = nil) { self.domain = domain; self.reason = reason }
}

public struct CalendarBusyInterval: Codable, Sendable, Equatable {
    public var start: String
    public var end: String
    public init(start: String, end: String) { self.start = start; self.end = end }
    public init(start: Date, end: Date) { self.init(start: CalendarDateCoding.string(start), end: CalendarDateCoding.string(end)) }
    public var startDate: Date? { CalendarDateCoding.date(start) }
    public var endDate: Date? { CalendarDateCoding.date(end) }
}

public struct CalendarFreeBusyCalendar: Codable, Sendable, Equatable {
    public var busy: [CalendarBusyInterval]
    public var errors: [CalendarAPIErrorDetail]?
    public init(busy: [CalendarBusyInterval] = [], errors: [CalendarAPIErrorDetail]? = nil) { self.busy = busy; self.errors = errors }
    enum CodingKeys: String, CodingKey { case busy, errors }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBusy = try c.decodeIfPresent([CalendarBusyInterval].self, forKey: .busy)
        errors = try c.decodeIfPresent([CalendarAPIErrorDetail].self, forKey: .errors)
        guard decodedBusy != nil || errors?.isEmpty == false else {
            throw DecodingError.dataCorruptedError(forKey: .busy, in: c, debugDescription: "Availability must contain busy intervals or an error")
        }
        busy = decodedBusy ?? []
    }
}

public struct CalendarFreeBusyResponse: Codable, Sendable, Equatable {
    public var timeMin: String?
    public var timeMax: String?
    public var calendars: [String: CalendarFreeBusyCalendar]
    public init(timeMin: String? = nil, timeMax: String? = nil, calendars: [String: CalendarFreeBusyCalendar] = [:]) {
        self.timeMin = timeMin; self.timeMax = timeMax; self.calendars = calendars
    }
}

public struct CalendarACLRule: CalendarResource, Identifiable, Hashable {
    public var rawValue: [String: CalendarJSON]
    public init(rawValue: [String: CalendarJSON]) { self.rawValue = rawValue }
    public init(id: String = "", role: String, scopeType: String = "user", scopeValue: String? = nil) {
        rawValue = ["role": .string(role)]
        if !id.isEmpty { self.id = id }
        var scope: [String: CalendarJSON] = ["type": .string(scopeType)]
        if let scopeValue { scope["value"] = .string(scopeValue) }
        rawValue["scope"] = .object(scope)
    }
    public var id: String { get { value("id") ?? "" } set { set("id", newValue) } }
    public var role: String { get { value("role") ?? "none" } set { set("role", newValue) } }
    public var etag: String? { get { value("etag") } set { set("etag", newValue) } }
    public var scopeType: String? { rawValue["scope"]?.objectValue?["type"]?.stringValue }
    public var scopeValue: String? { rawValue["scope"]?.objectValue?["value"]?.stringValue }
}

public struct CalendarACLPage: Codable, Sendable, Equatable {
    public var items: [CalendarACLRule]
    public var nextPageToken: String?
    public init(items: [CalendarACLRule] = [], nextPageToken: String? = nil) { self.items = items; self.nextPageToken = nextPageToken }
    enum CodingKeys: String, CodingKey { case items, nextPageToken }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([CalendarACLRule].self, forKey: .items) ?? []
        nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}
