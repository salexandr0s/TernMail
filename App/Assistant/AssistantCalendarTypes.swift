import Foundation
import GmailAPI
import MailStore
import SyncEngine

struct AssistantCalendarKey: Hashable, Sendable, Codable {
    let accountID: String
    let calendarID: String
}

struct AssistantCalendarScope: Equatable, Sendable {
    var access: [AssistantCalendarKey: CalendarAssistantAccess] = [:]
    var revision = 0
    var hasAccess: Bool { access.values.contains { $0 != .off } }

    func allows(_ key: AssistantCalendarKey, details: Bool = false) -> Bool {
        let permission = access[key] ?? .off
        return details ? permission == .details : permission != .off
    }
}

struct AssistantCalendarDescriptor: Sendable {
    let key: AssistantCalendarKey
    let title: String
    let canWrite: Bool
    let includeInScheduling: Bool
    var timeZoneIdentifier: String? = nil
}

struct AssistantCalendarProposal: Identifiable, Sendable, Equatable {
    let id: UUID
    let calendar: AssistantCalendarKey
    let title: String
    let accessRevision: Int
}

/// A checked interval carries the complete calendar set so choosing it can
/// repeat the same availability check before a reply draft is requested.
struct AssistantAvailabilityChoice: Identifiable, Sendable, Equatable {
    let id: UUID
    let calendarKeys: [AssistantCalendarKey]
    let start: Date
    let end: Date
    let timeZoneIdentifier: String
    let checkedAt: Date
    let accessRevision: Int

    init(id: UUID = UUID(), calendarKeys: [AssistantCalendarKey], start: Date, end: Date,
         timeZoneIdentifier: String, checkedAt: Date, accessRevision: Int) {
        self.id = id; self.calendarKeys = calendarKeys; self.start = start; self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier; self.checkedAt = checkedAt; self.accessRevision = accessRevision
    }

    var displayTitle: String {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return formatter.string(from: start, to: end)
    }
}

/// Injected reads and proposal preparation keep assistant tools independent of
/// view state. None of these closures can approve or submit a calendar write.
@MainActor
struct CalendarAssistantBindings {
    let calendars: () -> [AssistantCalendarDescriptor]
    let read: (AssistantCalendarKey, String) async throws -> GoogleCalendarEvent
    let query: (AssistantCalendarKey, Date, Date) async throws -> CalendarOccurrenceResult
    let availability: (String, [String], Date, Date, CalendarWorkingHours) async throws -> CalendarAvailabilityResult
    let prepare: (AssistantCalendarKey, GoogleCalendarEvent, GoogleCalendarEvent?) throws -> UUID
    let workingHours: () -> CalendarWorkingHours
    var prepareDeletion: ((AssistantCalendarKey, GoogleCalendarEvent) throws -> UUID)? = nil
}
