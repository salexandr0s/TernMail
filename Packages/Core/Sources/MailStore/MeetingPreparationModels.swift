import Foundation
import GmailAPI

public enum MeetingPreparationOriginalStart: Codable, Hashable, Sendable {
    case allDay(date: String)
    case timed(instant: Date)

    var storageKey: String {
        switch self {
        case .allDay(let date): "date:" + date
        case .timed(let instant):
            // Date's reference-epoch bits retain subsecond precision without depending on a locale.
            "time:" + String((instant.timeIntervalSinceReferenceDate == 0 ? 0 : instant.timeIntervalSinceReferenceDate).bitPattern)
        }
    }

    func validate() throws {
        switch self {
        case .allDay(let date):
            guard CalendarDateTime(date: date).resolvedDate(fallbackTimeZone: .gmt) != nil else {
                throw MeetingPreparationStoreError.invalidOccurrence
            }
        case .timed(let instant):
            guard instant.timeIntervalSinceReferenceDate.isFinite else { throw MeetingPreparationStoreError.invalidOccurrence }
        }
    }
}

public enum MeetingPreparationOccurrenceIdentity: Codable, Hashable, Sendable {
    case single(eventID: String)
    case recurring(seriesID: String, originalStart: MeetingPreparationOriginalStart)

    var storageKey: String {
        switch self {
        case .single(let eventID): "event:" + meetingPreparationComponent(eventID)
        case .recurring(let seriesID, let originalStart):
            "occurrence:" + meetingPreparationComponent(seriesID) + originalStart.storageKey
        }
    }

    func validate() throws {
        switch self {
        case .single(let eventID):
            guard !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPreparationStoreError.invalidOccurrence }
        case .recurring(let seriesID, let originalStart):
            guard !seriesID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPreparationStoreError.invalidOccurrence }
            try originalStart.validate()
        }
    }
}

/// Recurring identity follows the original start, so moving an occurrence keeps its source choices.
public struct MeetingPreparationOccurrence: Codable, Hashable, Sendable, Identifiable {
    public let eventAccountID: String
    public let calendarID: String
    public let identity: MeetingPreparationOccurrenceIdentity

    public var id: String { meetingPreparationComponent(eventAccountID) + meetingPreparationComponent(calendarID) + identity.storageKey }

    public init(eventAccountID: String, calendarID: String, identity: MeetingPreparationOccurrenceIdentity) throws {
        self.eventAccountID = eventAccountID; self.calendarID = calendarID; self.identity = identity
        try validate()
    }

    public init(eventAccountID: String, calendarID: String, event: GoogleCalendarEvent) throws {
        guard !event.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPreparationStoreError.invalidOccurrence }
        let identity: MeetingPreparationOccurrenceIdentity
        if let seriesID = event.recurringEventId {
            guard let original = event.originalStartTime else { throw MeetingPreparationStoreError.invalidOccurrence }
            let start: MeetingPreparationOriginalStart
            if original.isAllDay, let date = original.date {
                start = .allDay(date: date)
            } else if original.date == nil, original.dateTime != nil,
                      let instant = original.resolvedDate(fallbackTimeZone: .gmt) {
                start = .timed(instant: instant)
            } else { throw MeetingPreparationStoreError.invalidOccurrence }
            identity = .recurring(seriesID: seriesID, originalStart: start)
        } else {
            guard event.recurrence?.isEmpty ?? true else { throw MeetingPreparationStoreError.requiresOccurrence }
            guard event.originalStartTime == nil else { throw MeetingPreparationStoreError.invalidOccurrence }
            identity = .single(eventID: event.id)
        }
        try self.init(eventAccountID: eventAccountID, calendarID: calendarID, identity: identity)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(eventAccountID: values.decode(String.self, forKey: .eventAccountID),
            calendarID: values.decode(String.self, forKey: .calendarID),
            identity: values.decode(MeetingPreparationOccurrenceIdentity.self, forKey: .identity))
    }

    func validate() throws {
        guard [eventAccountID, calendarID].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MeetingPreparationStoreError.invalidOccurrence
        }
        try identity.validate()
    }

    private enum CodingKeys: String, CodingKey { case eventAccountID, calendarID, identity }
}

public enum MeetingPreparationSourceChoice: String, Codable, Sendable, CaseIterable {
    case include, exclude
}

public struct MeetingPreparationSourcePreference: Codable, Equatable, Sendable, Identifiable {
    public let occurrence: MeetingPreparationOccurrence
    public let mailAccountID: String
    public let threadID: String
    public let choice: MeetingPreparationSourceChoice
    public let updatedAt: Date
    public let revision: String

    public var id: String { meetingPreparationComponent(occurrence.id) + meetingPreparationComponent(mailAccountID) + meetingPreparationComponent(threadID) }

    public init(occurrence: MeetingPreparationOccurrence, mailAccountID: String, threadID: String,
                choice: MeetingPreparationSourceChoice, updatedAt: Date = Date(), revision: String = UUID().uuidString) {
        self.occurrence = occurrence; self.mailAccountID = mailAccountID; self.threadID = threadID
        self.choice = choice; self.updatedAt = updatedAt; self.revision = revision
    }
}

public enum MeetingPreparationStoreError: Error, LocalizedError, Equatable, Sendable {
    case requiresOccurrence, invalidOccurrence, unavailableAccount, conflict, invalidPreference

    public var errorDescription: String? {
        switch self {
        case .requiresOccurrence: "Choose an occurrence of this recurring event."
        case .invalidOccurrence: "This event occurrence is unavailable. Refresh the calendar and try again."
        case .unavailableAccount: "An account used by this preparation is no longer available."
        case .conflict: "The conversation choices changed. Reload them before saving."
        case .invalidPreference: "This conversation choice could not be saved."
        }
    }
}

private func meetingPreparationComponent(_ value: String) -> String { "\(value.utf8.count):\(value)" }
