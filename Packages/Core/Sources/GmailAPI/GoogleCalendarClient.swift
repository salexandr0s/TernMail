import Foundation

public struct CalendarEventQuery: Sendable, Equatable {
    public var pageToken: String?
    public var syncToken: String?
    public var timeMin: Date?
    public var timeMax: Date?
    public var iCalUID: String?
    public var query: String?
    public var singleEvents: Bool
    public var showDeleted: Bool
    public var maxResults: Int
    public var timeZone: String?
    public var privateExtendedProperty: [String]?
    public init(pageToken: String? = nil, syncToken: String? = nil, timeMin: Date? = nil, timeMax: Date? = nil,
                iCalUID: String? = nil, query: String? = nil, singleEvents: Bool = false,
                showDeleted: Bool = true, maxResults: Int = 2500, timeZone: String? = nil,
                privateExtendedProperty: [String]? = nil) {
        self.pageToken = pageToken; self.syncToken = syncToken; self.timeMin = timeMin; self.timeMax = timeMax
        self.iCalUID = iCalUID; self.query = query; self.singleEvents = singleEvents
        self.showDeleted = showDeleted; self.maxResults = maxResults; self.timeZone = timeZone
        self.privateExtendedProperty = privateExtendedProperty
    }
}

public enum CalendarAPIError: Error, Sendable, Equatable, LocalizedError {
    case syncTokenExpired, unsupportedOperation
    public var errorDescription: String? {
        switch self {
        case .syncTokenExpired: "Calendar synchronization needs to restart."
        case .unsupportedOperation: "This calendar operation is unavailable."
        }
    }
}

/// API boundary shared by synchronization, queued actions and test services.
public protocol CalendarService: Sendable {
    func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage
    func events(calendarID: String, query: CalendarEventQuery) async throws -> CalendarEventPage
    func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent
    func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String) async throws -> GoogleCalendarEvent
    func importEvent(calendarID: String, event: GoogleCalendarEvent) async throws -> GoogleCalendarEvent
    func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent
    func deleteEvent(calendarID: String, eventID: String, etag: String?, sendUpdates: String) async throws
    func moveEvent(calendarID: String, eventID: String, destination: String, etag: String?, sendUpdates: String) async throws -> GoogleCalendarEvent
    func instances(calendarID: String, eventID: String, query: CalendarEventQuery) async throws -> CalendarEventPage
    func freeBusy(calendarIDs: [String], start: Date, end: Date, timeZone: String) async throws -> CalendarFreeBusyResponse
    func patchCalendarList(calendarID: String, fields: [String: CalendarJSON], etag: String?) async throws -> GoogleCalendarEntry
    func insertCalendarList(calendarID: String) async throws -> GoogleCalendarEntry
    func deleteCalendarList(calendarID: String) async throws
    func createCalendar(summary: String, timeZone: String) async throws -> GoogleCalendarEntry
    func calendar(calendarID: String) async throws -> GoogleCalendarEntry
    func patchCalendar(calendarID: String, fields: [String: CalendarJSON], etag: String?) async throws -> GoogleCalendarEntry
    func deleteCalendar(calendarID: String, etag: String?) async throws
    func acl(calendarID: String, pageToken: String?) async throws -> CalendarACLPage
    func insertACL(calendarID: String, rule: CalendarACLRule, sendNotifications: Bool) async throws -> CalendarACLRule
    func patchACL(calendarID: String, ruleID: String, fields: [String: CalendarJSON], etag: String?) async throws -> CalendarACLRule
    func deleteACL(calendarID: String, ruleID: String, etag: String?) async throws
}

/// A focused synthetic service may implement only the operations it exercises.
/// Missing operations fail rather than returning fabricated success.
extension CalendarService {
    public func calendarList(pageToken: String? = nil, syncToken: String? = nil) async throws -> CalendarListPage { throw CalendarAPIError.unsupportedOperation }
    public func events(calendarID: String, query: CalendarEventQuery = .init()) async throws -> CalendarEventPage { throw CalendarAPIError.unsupportedOperation }
    public func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent { throw CalendarAPIError.unsupportedOperation }
    public func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String = "all") async throws -> GoogleCalendarEvent { throw CalendarAPIError.unsupportedOperation }
    public func importEvent(calendarID: String, event: GoogleCalendarEvent) async throws -> GoogleCalendarEvent { throw CalendarAPIError.unsupportedOperation }
    public func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String? = nil, sendUpdates: String = "all") async throws -> GoogleCalendarEvent { throw CalendarAPIError.unsupportedOperation }
    public func deleteEvent(calendarID: String, eventID: String, etag: String? = nil, sendUpdates: String = "all") async throws { throw CalendarAPIError.unsupportedOperation }
    public func moveEvent(calendarID: String, eventID: String, destination: String, etag: String? = nil, sendUpdates: String = "all") async throws -> GoogleCalendarEvent { throw CalendarAPIError.unsupportedOperation }
    public func instances(calendarID: String, eventID: String, query: CalendarEventQuery = .init()) async throws -> CalendarEventPage { throw CalendarAPIError.unsupportedOperation }
    public func freeBusy(calendarIDs: [String], start: Date, end: Date, timeZone: String) async throws -> CalendarFreeBusyResponse { throw CalendarAPIError.unsupportedOperation }
    public func patchCalendarList(calendarID: String, fields: [String: CalendarJSON], etag: String? = nil) async throws -> GoogleCalendarEntry { throw CalendarAPIError.unsupportedOperation }
    public func insertCalendarList(calendarID: String) async throws -> GoogleCalendarEntry { throw CalendarAPIError.unsupportedOperation }
    public func deleteCalendarList(calendarID: String) async throws { throw CalendarAPIError.unsupportedOperation }
    public func createCalendar(summary: String, timeZone: String) async throws -> GoogleCalendarEntry { throw CalendarAPIError.unsupportedOperation }
    public func calendar(calendarID: String) async throws -> GoogleCalendarEntry { throw CalendarAPIError.unsupportedOperation }
    public func patchCalendar(calendarID: String, fields: [String: CalendarJSON], etag: String? = nil) async throws -> GoogleCalendarEntry { throw CalendarAPIError.unsupportedOperation }
    public func deleteCalendar(calendarID: String, etag: String? = nil) async throws { throw CalendarAPIError.unsupportedOperation }
    public func acl(calendarID: String, pageToken: String? = nil) async throws -> CalendarACLPage { throw CalendarAPIError.unsupportedOperation }
    public func insertACL(calendarID: String, rule: CalendarACLRule, sendNotifications: Bool = true) async throws -> CalendarACLRule { throw CalendarAPIError.unsupportedOperation }
    public func patchACL(calendarID: String, ruleID: String, fields: [String: CalendarJSON], etag: String? = nil) async throws -> CalendarACLRule { throw CalendarAPIError.unsupportedOperation }
    public func deleteACL(calendarID: String, ruleID: String, etag: String? = nil) async throws { throw CalendarAPIError.unsupportedOperation }
}

public struct GoogleCalendarClient: CalendarService, Sendable {
    private let session: GoogleSession
    public init(session: GoogleSession) { self.session = session }
    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = GoogleSession.defaultTransport) {
        session = GoogleSession(tokens: tokens, transport: transport)
    }

    public func calendarList(pageToken: String? = nil, syncToken: String? = nil) async throws -> CalendarListPage {
        var query = [URLQueryItem(name: "maxResults", value: "250"), URLQueryItem(name: "showDeleted", value: "true"), URLQueryItem(name: "showHidden", value: "true")]
        add("pageToken", pageToken, to: &query); add("syncToken", syncToken, to: &query)
        return try await resource(["users", "me", "calendarList"], query: query, syncRequest: syncToken != nil)
    }

    public func events(calendarID: String, query: CalendarEventQuery = .init()) async throws -> CalendarEventPage {
        try await resource(["calendars", calendarID, "events"], query: eventQuery(query), syncRequest: query.syncToken != nil)
    }

    public func event(calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
        try await resource(["calendars", calendarID, "events", eventID])
    }

    public func insertEvent(calendarID: String, event: GoogleCalendarEvent, sendUpdates: String = "all") async throws -> GoogleCalendarEvent {
        guard event.id.isEmpty || event.iCalUID == nil else { throw GmailError.invalidRequest("Use either an event ID or an iCalendar UID when creating an event") }
        try validateEvent(event)
        return try await resource(["calendars", calendarID, "events"], method: "POST", query: mutationQuery(sendUpdates), body: event.writableFields)
    }

    public func importEvent(calendarID: String, event: GoogleCalendarEvent) async throws -> GoogleCalendarEvent {
        guard let uid = event.iCalUID, !uid.isEmpty else { throw GmailError.invalidRequest("An imported event needs its iCalendar UID") }
        try validateEvent(event)
        var fields = event.writableFields
        fields.removeValue(forKey: "id")
        if let organizer = event.rawValue["organizer"] { fields["organizer"] = organizer }
        return try await resource(["calendars", calendarID, "events", "import"], method: "POST", query: [
            URLQueryItem(name: "conferenceDataVersion", value: "1"), URLQueryItem(name: "supportsAttachments", value: "true"),
        ], body: fields)
    }

    public func patchEvent(calendarID: String, eventID: String, fields: [String: CalendarJSON], etag: String? = nil, sendUpdates: String = "all") async throws -> GoogleCalendarEvent {
        try await resource(["calendars", calendarID, "events", eventID], method: "PATCH", query: mutationQuery(sendUpdates), body: fields, etag: etag)
    }

    public func deleteEvent(calendarID: String, eventID: String, etag: String? = nil, sendUpdates: String = "all") async throws {
        try await empty(["calendars", calendarID, "events", eventID], method: "DELETE", query: [sendUpdatesItem(sendUpdates)], etag: etag)
    }

    public func moveEvent(calendarID: String, eventID: String, destination: String, etag: String? = nil, sendUpdates: String = "all") async throws -> GoogleCalendarEvent {
        guard !destination.isEmpty else { throw GmailError.invalidRequest("Destination calendar") }
        return try await resource(["calendars", calendarID, "events", eventID, "move"], method: "POST", query: [
            URLQueryItem(name: "destination", value: destination), sendUpdatesItem(sendUpdates),
        ], etag: etag)
    }

    public func instances(calendarID: String, eventID: String, query: CalendarEventQuery = .init()) async throws -> CalendarEventPage {
        guard query.syncToken == nil, query.iCalUID == nil, query.query == nil, query.privateExtendedProperty == nil else {
            throw GmailError.invalidRequest("Unsupported recurring instance query")
        }
        var parameters = try eventQuery(query)
        parameters.removeAll { $0.name == "singleEvents" }
        return try await resource(["calendars", calendarID, "events", eventID, "instances"], query: parameters)
    }

    public func freeBusy(calendarIDs: [String], start: Date, end: Date, timeZone: String) async throws -> CalendarFreeBusyResponse {
        guard end > start, !calendarIDs.isEmpty, calendarIDs.count <= 50, !calendarIDs.contains(where: \.isEmpty), TimeZone(identifier: timeZone) != nil else {
            throw GmailError.invalidRequest("Availability query needs a date range, time zone and 1 to 50 calendars")
        }
        let body: [String: CalendarJSON] = [
            "timeMin": .string(CalendarDateCoding.string(start)), "timeMax": .string(CalendarDateCoding.string(end)),
            "timeZone": .string(timeZone), "calendarExpansionMax": .number(50),
            "items": .array(calendarIDs.map { .object(["id": .string($0)]) }),
        ]
        return try await resource(["freeBusy"], method: "POST", body: body)
    }

    public func patchCalendarList(calendarID: String, fields: [String: CalendarJSON], etag: String? = nil) async throws -> GoogleCalendarEntry {
        try await resource(["users", "me", "calendarList", calendarID], method: "PATCH", query: [URLQueryItem(name: "colorRgbFormat", value: "true")], body: fields, etag: etag)
    }

    public func insertCalendarList(calendarID: String) async throws -> GoogleCalendarEntry {
        guard !calendarID.isEmpty else { throw GmailError.invalidRequest("Calendar ID") }
        return try await resource(["users", "me", "calendarList"], method: "POST", body: ["id": .string(calendarID)])
    }

    public func deleteCalendarList(calendarID: String) async throws { try await empty(["users", "me", "calendarList", calendarID], method: "DELETE") }

    public func createCalendar(summary: String, timeZone: String) async throws -> GoogleCalendarEntry {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, TimeZone(identifier: timeZone) != nil else {
            throw GmailError.invalidRequest("Calendar name and time zone")
        }
        return try await resource(["calendars"], method: "POST", body: ["summary": .string(summary), "timeZone": .string(timeZone)])
    }

    public func calendar(calendarID: String) async throws -> GoogleCalendarEntry {
        try await resource(["calendars", calendarID])
    }

    public func patchCalendar(calendarID: String, fields: [String: CalendarJSON], etag: String? = nil) async throws -> GoogleCalendarEntry {
        try await resource(["calendars", calendarID], method: "PATCH", body: fields, etag: etag)
    }

    public func deleteCalendar(calendarID: String, etag: String? = nil) async throws { try await empty(["calendars", calendarID], method: "DELETE", etag: etag) }

    public func acl(calendarID: String, pageToken: String? = nil) async throws -> CalendarACLPage {
        var query = [URLQueryItem(name: "maxResults", value: "250")]
        add("pageToken", pageToken, to: &query)
        return try await resource(["calendars", calendarID, "acl"], query: query)
    }

    public func insertACL(calendarID: String, rule: CalendarACLRule, sendNotifications: Bool = true) async throws -> CalendarACLRule {
        try await resource(["calendars", calendarID, "acl"], method: "POST", query: [URLQueryItem(name: "sendNotifications", value: String(sendNotifications))], body: rule.rawValue.filter { !["id", "etag", "kind"].contains($0.key) })
    }

    public func patchACL(calendarID: String, ruleID: String, fields: [String: CalendarJSON], etag: String? = nil) async throws -> CalendarACLRule {
        try await resource(["calendars", calendarID, "acl", ruleID], method: "PATCH", body: fields, etag: etag)
    }

    public func deleteACL(calendarID: String, ruleID: String, etag: String? = nil) async throws { try await empty(["calendars", calendarID, "acl", ruleID], method: "DELETE", etag: etag) }

    private func eventQuery(_ value: CalendarEventQuery) throws -> [URLQueryItem] {
        if value.syncToken != nil {
            guard value.timeMin == nil, value.timeMax == nil, value.iCalUID == nil, value.query == nil,
                  value.privateExtendedProperty == nil, value.showDeleted else {
                throw GmailError.invalidRequest("Sync token cannot be combined with event filters")
            }
        }
        if let start = value.timeMin, let end = value.timeMax, end <= start { throw GmailError.invalidRequest("Calendar date range") }
        var query = [
            URLQueryItem(name: "singleEvents", value: String(value.singleEvents)),
            URLQueryItem(name: "showDeleted", value: String(value.showDeleted)),
            URLQueryItem(name: "maxResults", value: String(min(max(1, value.maxResults), 2500))),
        ]
        add("pageToken", value.pageToken, to: &query); add("syncToken", value.syncToken, to: &query)
        add("timeMin", value.timeMin.map(CalendarDateCoding.string), to: &query)
        add("timeMax", value.timeMax.map(CalendarDateCoding.string), to: &query)
        add("iCalUID", value.iCalUID, to: &query); add("q", value.query, to: &query); add("timeZone", value.timeZone, to: &query)
        for property in value.privateExtendedProperty ?? [] { add("privateExtendedProperty", property, to: &query) }
        return query
    }

    private func validateEvent(_ event: GoogleCalendarEvent) throws {
        guard let start = event.start, let end = event.end, start.isAllDay == end.isAllDay,
              let starts = start.resolvedDate(), let ends = end.resolvedDate(), ends >= starts,
              (!start.isAllDay || ends > starts) else { throw GmailError.invalidRequest("Event start and end") }
        if let rules = event.recurrence, !rules.isEmpty, !start.isAllDay {
            guard let zone = start.timeZone, TimeZone(identifier: zone) != nil else { throw GmailError.invalidRequest("Recurring events need a time zone") }
        }
    }

    private func mutationQuery(_ sendUpdates: String) throws -> [URLQueryItem] {
        [try sendUpdatesItem(sendUpdates), URLQueryItem(name: "conferenceDataVersion", value: "1"), URLQueryItem(name: "supportsAttachments", value: "true")]
    }

    private func sendUpdatesItem(_ value: String) throws -> URLQueryItem {
        guard ["all", "externalOnly", "none"].contains(value) else { throw GmailError.invalidRequest("Calendar update notification mode") }
        return URLQueryItem(name: "sendUpdates", value: value)
    }

    private func add(_ name: String, _ value: String?, to query: inout [URLQueryItem]) {
        if let value { query.append(URLQueryItem(name: name, value: value)) }
    }

    private func request(_ segments: [String], method: String, query: [URLQueryItem], body: [String: CalendarJSON]?, etag: String?) throws -> URLRequest {
        guard !segments.contains(where: \.isEmpty) else { throw GmailError.invalidRequest("Calendar resource identity") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var components = URLComponents()
        components.scheme = "https"; components.host = "www.googleapis.com"
        let encodedSegments = try segments.map { segment in
            guard let value = segment.addingPercentEncoding(withAllowedCharacters: allowed) else { throw GmailError.invalidRequest("Calendar resource identity") }
            return value
        }
        components.percentEncodedPath = "/calendar/v3/" + encodedSegments.joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw GmailError.invalidRequest("Calendar request") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body { request.httpBody = try session.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        return request
    }

    private func resource<Value: Decodable>(_ segments: [String], method: String = "GET", query: [URLQueryItem] = [],
                                           body: [String: CalendarJSON]? = nil, etag: String? = nil, syncRequest: Bool = false) async throws -> Value {
        do {
            let result: Value = try session.decode(try await session.send(request(segments, method: method, query: query, body: body, etag: etag)).data)
            let identities: [String]
            switch result {
            case let event as GoogleCalendarEvent: identities = [event.id]
            case let calendar as GoogleCalendarEntry: identities = [calendar.id]
            case let page as CalendarEventPage: identities = page.items.map(\.id)
            case let page as CalendarListPage: identities = page.items.map(\.id)
            case let rule as CalendarACLRule: identities = [rule.id]
            case let page as CalendarACLPage: identities = page.items.map(\.id)
            default: identities = []
            }
            guard !identities.contains(where: \.isEmpty) else { throw GmailError.decoding("Calendar resource identity") }
            return result
        } catch GmailError.http(let status, _) where syncRequest && status == 410 { throw CalendarAPIError.syncTokenExpired }
    }

    private func empty(_ segments: [String], method: String, query: [URLQueryItem] = [], etag: String? = nil) async throws {
        _ = try await session.send(request(segments, method: method, query: query, body: nil, etag: etag))
    }
}
