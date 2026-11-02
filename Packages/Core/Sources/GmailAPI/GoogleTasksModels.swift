import Foundation

public struct GoogleTaskList: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var etag: String?
    public var updated: String?

    public init(id: String, title: String, etag: String? = nil, updated: String? = nil) {
        self.id = id; self.title = title; self.etag = etag; self.updated = updated
    }
}

public struct GoogleTask: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var notes: String?
    /// Google's RFC 3339 value carries a calendar day, not a local time.
    public var due: String?
    public var status: String
    public var etag: String?
    public var parent: String?
    public var position: String?
    public var updated: String?
    public var completed: String?
    public var hidden: Bool?
    public var deleted: Bool?
    public var webViewLink: String?

    public var isCompleted: Bool { status == "completed" }
    public var dueDay: String? { due.flatMap(GoogleTaskDateCoding.day) }

    public init(id: String, title: String, notes: String? = nil, due: String? = nil,
                status: String = "needsAction", etag: String? = nil, parent: String? = nil,
                position: String? = nil, updated: String? = nil, completed: String? = nil,
                hidden: Bool? = nil, deleted: Bool? = nil, webViewLink: String? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.due = due; self.status = status
        self.etag = etag; self.parent = parent; self.position = position; self.updated = updated
        self.completed = completed; self.hidden = hidden; self.deleted = deleted; self.webViewLink = webViewLink
    }

    enum CodingKeys: String, CodingKey {
        case id, title, notes, due, status, etag, parent, position, updated, completed, hidden, deleted, webViewLink
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "needsAction"
        notes = try values.decodeIfPresent(String.self, forKey: .notes)
        due = try values.decodeIfPresent(String.self, forKey: .due)
        etag = try values.decodeIfPresent(String.self, forKey: .etag)
        parent = try values.decodeIfPresent(String.self, forKey: .parent)
        position = try values.decodeIfPresent(String.self, forKey: .position)
        updated = try values.decodeIfPresent(String.self, forKey: .updated)
        completed = try values.decodeIfPresent(String.self, forKey: .completed)
        hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden)
        deleted = try values.decodeIfPresent(Bool.self, forKey: .deleted)
        webViewLink = try values.decodeIfPresent(String.self, forKey: .webViewLink)
    }
}

public struct GoogleTaskListPage: Decodable, Sendable, Equatable {
    public var items: [GoogleTaskList]
    public var nextPageToken: String?

    public init(items: [GoogleTaskList] = [], nextPageToken: String? = nil) {
        self.items = items; self.nextPageToken = nextPageToken
    }

    enum CodingKeys: String, CodingKey { case items, nextPageToken }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([GoogleTaskList].self, forKey: .items) ?? []
        nextPageToken = try values.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

public struct GoogleTaskPage: Decodable, Sendable, Equatable {
    public var items: [GoogleTask]
    public var nextPageToken: String?

    public init(items: [GoogleTask] = [], nextPageToken: String? = nil) {
        self.items = items; self.nextPageToken = nextPageToken
    }

    enum CodingKeys: String, CodingKey { case items, nextPageToken }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([GoogleTask].self, forKey: .items) ?? []
        nextPageToken = try values.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

public struct GoogleTaskDraft: Sendable, Equatable, Encodable {
    public var title: String
    public var notes: String?
    /// A date in YYYY-MM-DD format. Google Tasks does not expose scheduled times.
    public var due: String?

    public init(title: String, notes: String? = nil, due: String? = nil) {
        self.title = title; self.notes = notes; self.due = due
    }

    enum CodingKeys: String, CodingKey { case title, notes, due }
    public func encode(to encoder: any Encoder) throws {
        try GoogleTaskValidation.content(title: title, notes: notes)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encodeIfPresent(notes, forKey: .notes)
        if let due { try values.encode(GoogleTaskDateCoding.wireDate(due), forKey: .due) }
    }
}

public enum GoogleTaskDueChange: Sendable, Equatable {
    case unchanged
    case set(String)
    case clear
}

/// Unspecified fields remain unchanged, including provider fields this app does not edit.
public struct GoogleTaskUpdate: Sendable, Equatable, Encodable {
    public var title: String?
    /// Pass an empty string to clear notes; nil preserves them.
    public var notes: String?
    public var due: GoogleTaskDueChange
    public var isCompleted: Bool?

    public init(title: String? = nil, notes: String? = nil,
                due: GoogleTaskDueChange = .unchanged, isCompleted: Bool? = nil) {
        self.title = title; self.notes = notes; self.due = due; self.isCompleted = isCompleted
    }

    enum CodingKeys: String, CodingKey { case title, notes, due, status, completed }
    public func encode(to encoder: any Encoder) throws {
        try GoogleTaskValidation.content(title: title, notes: notes)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(notes, forKey: .notes)
        switch due {
        case .unchanged: break
        case .set(let day): try values.encode(GoogleTaskDateCoding.wireDate(day), forKey: .due)
        case .clear: try values.encodeNil(forKey: .due)
        }
        if let isCompleted {
            try values.encode(isCompleted ? "completed" : "needsAction", forKey: .status)
            if !isCompleted { try values.encodeNil(forKey: .completed) }
        }
    }
}

public enum GoogleTaskDateCoding {
    public static func string(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Resolves the day as local midnight, avoiding a shift to yesterday west of UTC.
    public static func date(_ value: String, timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        guard let day = day(value) else { return nil }
        return CalendarDateTime(date: day).resolvedDate(fallbackTimeZone: timeZone)
    }

    public static func day(_ value: String) -> String? {
        guard value.count == 10 || CalendarDateCoding.date(value) != nil else { return nil }
        let day = String(value.prefix(10))
        guard let utc = TimeZone(secondsFromGMT: 0),
              CalendarDateTime(date: day).resolvedDate(fallbackTimeZone: utc) != nil else { return nil }
        return day
    }

    static func wireDate(_ value: String) throws -> String {
        guard value.count == 10, let day = day(value) else {
            throw GmailError.invalidRequest("A task date must use YYYY-MM-DD")
        }
        return day + "T00:00:00.000Z"
    }
}

private enum GoogleTaskValidation {
    static func content(title: String?, notes: String?) throws {
        if let title {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 1024 else {
                throw GmailError.invalidRequest("A task title must contain 1 to 1024 characters")
            }
        }
        if let notes, notes.count > 8192 {
            throw GmailError.invalidRequest("Task notes must contain at most 8192 characters")
        }
    }
}
