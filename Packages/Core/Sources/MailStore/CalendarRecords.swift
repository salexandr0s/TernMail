import Foundation
import GmailAPI

public enum CalendarAssistantAccess: String, Codable, Sendable, CaseIterable {
    case off, availability, details
}

public struct CalendarPreferences: Codable, Sendable, Equatable, Identifiable {
    public var accountID: String
    public var calendarID: String
    public var visible: Bool
    public var assistantAccess: CalendarAssistantAccess
    public var includeInScheduling: Bool
    public var notificationsEnabled: Bool
    public var id: String { accountID + "/" + calendarID }

    public init(accountID: String, calendarID: String, visible: Bool = true,
                assistantAccess: CalendarAssistantAccess = .off, includeInScheduling: Bool = false,
                notificationsEnabled: Bool = false) {
        self.accountID = accountID; self.calendarID = calendarID; self.visible = visible
        self.assistantAccess = assistantAccess; self.includeInScheduling = includeInScheduling
        self.notificationsEnabled = notificationsEnabled
    }
}

public enum CalendarMutation: Codable, Sendable, Equatable {
    case create(GoogleCalendarEvent)
    case update(eventID: String, fields: [String: CalendarJSON], etag: String?)
    case delete(eventID: String, etag: String?)
    case deleteFollowing(eventID: String, etag: String?, originalStart: CalendarDateTime)
    case importEvent(GoogleCalendarEvent)
    case importSeries(master: GoogleCalendarEvent, exceptions: [GoogleCalendarEvent])
    case respond(eventID: String, status: String, etag: String?)
    case move(eventID: String, destination: String, etag: String?)
    /// `originalStart` identifies the chosen occurrence before it was moved.
    /// Exceptions on/after that point are reset only after explicit review.
    case splitSeries(eventID: String, etag: String?, originalStart: CalendarDateTime,
                     followingEvent: GoogleCalendarEvent, resetExceptionsConfirmed: Bool)

    public var eventID: String? {
        switch self {
        case .create(let event), .importEvent(let event): event.id.isEmpty ? nil : event.id
        case .importSeries(let master, _): master.id.isEmpty ? nil : master.id
        case .update(let id, _, _), .delete(let id, _), .deleteFollowing(let id, _, _), .respond(let id, _, _),
             .move(let id, _, _), .splitSeries(let id, _, _, _, _): id
        }
    }
}

public struct CalendarOperation: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case proposed, queued, running, completed, conflicted, failed, cancelled
    }
    public var id: String
    public var accountID: String
    public var calendarID: String
    public var mutation: CalendarMutation
    public var sendUpdates: String
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    public var attempts: Int
    /// Nil on older receipts; treat those attempted writes as uncertain.
    public var hasUncertainOutcome: Bool?
    public var errorMessage: String?
    public var resultEvent: GoogleCalendarEvent?
    public var beforeEvent: GoogleCalendarEvent?
    /// Binds an approved email candidate to this operation in the queue transaction.
    public var sourceSuggestionID: String?
    /// A split resumes after trimming the original series, rather than trimming it twice.
    public var completedStep: Int
    public var preparedMutation: CalendarMutation?
    /// Exact original recurrence patch, persisted before a series split starts.
    public var preparedRecurrence: [String]?
    public var affectedEventVersions: [String: String]

    public init(id: String = UUID().uuidString.lowercased(), accountID: String, calendarID: String,
                mutation: CalendarMutation, sendUpdates: String = "all", status: Status = .proposed,
                createdAt: Date = .now, sourceSuggestionID: String? = nil) {
        self.id = id; self.accountID = accountID; self.calendarID = calendarID
        self.mutation = mutation; self.sendUpdates = sendUpdates; self.status = status
        self.createdAt = createdAt; self.updatedAt = createdAt; attempts = 0; completedStep = 0; hasUncertainOutcome = false
        affectedEventVersions = [:]
        self.sourceSuggestionID = sourceSuggestionID
    }
}

public struct CalendarSourceLink: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var accountID: String
    public var calendarID: String
    public var eventID: String
    public var threadID: String
    public var messageID: String
    public var invitationUID: String?
    public var recurrenceKey: String?
    public init(id: String = UUID().uuidString, accountID: String, calendarID: String, eventID: String,
                threadID: String, messageID: String, invitationUID: String? = nil, recurrenceKey: String? = nil) {
        self.id = id; self.accountID = accountID; self.calendarID = calendarID; self.eventID = eventID
        self.threadID = threadID; self.messageID = messageID; self.invitationUID = invitationUID
        self.recurrenceKey = recurrenceKey
    }
}

/// Retains user corrections and dismissals independently of disposable sync data.
public struct CalendarSuggestionRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var accountID: String
    public var threadID: String
    public var messageID: String
    public var sourceRevision: String
    public var event: GoogleCalendarEvent
    public var sourceText: String
    public var isDismissed: Bool
    public var isUserEdited: Bool
    public var operationID: String?
    public init(id: String, accountID: String, threadID: String, messageID: String, sourceRevision: String,
                event: GoogleCalendarEvent, sourceText: String, isDismissed: Bool = false,
                isUserEdited: Bool = false, operationID: String? = nil) {
        self.id = id; self.accountID = accountID; self.threadID = threadID; self.messageID = messageID
        self.sourceRevision = sourceRevision; self.event = event; self.sourceText = sourceText
        self.isDismissed = isDismissed; self.isUserEdited = isUserEdited; self.operationID = operationID
    }
}

public struct CalendarSyncState: Sendable, Equatable {
    public var syncToken: String?
    public var generation: Int
    public var revision: Int
    public var lastSyncedAt: Date?
    public init(syncToken: String? = nil, generation: Int = 0, revision: Int = 0, lastSyncedAt: Date? = nil) {
        self.syncToken = syncToken; self.generation = generation; self.revision = revision
        self.lastSyncedAt = lastSyncedAt
    }
}

public struct CalendarOccurrenceResult: Sendable, Equatable {
    public var events: [GoogleCalendarEvent]
    public var fetchedAt: Date?
    public var isStale: Bool
    public var isComplete: Bool
    public init(events: [GoogleCalendarEvent], fetchedAt: Date? = nil, isStale: Bool, isComplete: Bool) {
        self.events = events; self.fetchedAt = fetchedAt; self.isStale = isStale; self.isComplete = isComplete
    }
}

public enum CalendarStoreError: Error, Sendable, LocalizedError {
    case staleGeneration, invalidRecord, responseAlreadyPending
    public var errorDescription: String? {
        switch self {
        case .staleGeneration: "Calendar data changed while this request was loading. Refresh and try again."
        case .invalidRecord: "This calendar change is no longer available. Review it and try again."
        case .responseAlreadyPending: "A different reply to this invitation is already waiting to be sent."
        }
    }
}
