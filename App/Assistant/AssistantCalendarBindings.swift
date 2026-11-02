import Foundation
import MailStore
import SyncEngine

extension CalendarModel {
    var assistantScope: AssistantCalendarScope {
        var access: [AssistantCalendarKey: CalendarAssistantAccess] = [:]
        for owner in calendars where owner.aiAccess != .off && engines[owner.accountID] != nil {
            let key = AssistantCalendarKey(accountID: owner.accountID, calendarID: owner.calendarID)
            let requested = CalendarAssistantAccess(rawValue: owner.aiAccess.rawValue) ?? .off
            access[key] = requested == .details && !owner.entry.canReadDetails ? .availability : requested
        }
        return AssistantCalendarScope(access: access, revision: accessRevision)
    }

    /// A citation's permission cannot be revived by revoking and regranting it
    /// while its event or recurring master is loading.
    func openAssistantEvent(accountID: String, calendarID: String, eventID: String) async {
        let key = AssistantCalendarKey(accountID: accountID, calendarID: calendarID)
        let scope = assistantScope
        guard scope.allows(key, details: true) else { return }
        await openEvent(accountID: accountID, calendarID: calendarID, eventID: eventID, isAuthorized: { [weak self] in
            guard let self else { return false }
            let current = assistantScope
            return current.revision == scope.revision && current.allows(key, details: true)
        })
    }

    var assistantBindings: CalendarAssistantBindings {
        CalendarAssistantBindings(
            calendars: { [weak self] in
                guard let self else { return [] }
                return calendars.filter { engines[$0.accountID] != nil }.map {
                    .init(key: .init(accountID: $0.accountID, calendarID: $0.calendarID), title: $0.title,
                          canWrite: $0.canWrite, includeInScheduling: $0.useForScheduling,
                          timeZoneIdentifier: $0.entry.timeZone)
                }
            },
            read: { [weak self] key, eventID in
                guard let self else { throw CalendarAssistantTools.ToolError.accessChanged }
                return try await readEvent(accountID: key.accountID, calendarID: key.calendarID, eventID: eventID)
            },
            query: { [weak self] key, start, end in
                guard let self else { throw CalendarAssistantTools.ToolError.accessChanged }
                return try await queryEvents(accountID: key.accountID, calendarID: key.calendarID, start: start, end: end)
            },
            availability: { [weak self] accountID, calendarIDs, start, end, hours in
                guard let self, let engine = engines[accountID] else { throw CalendarAssistantTools.ToolError.accessChanged }
                return try await engine.availability(calendarIDs: calendarIDs, start: start, end: end, hours: hours)
            },
            prepare: { [weak self] key, event, original in
                guard let self, assistantScope.allows(key), calendars.contains(where: {
                    $0.accountID == key.accountID && $0.calendarID == key.calendarID && $0.canWrite
                }) else { throw CalendarAssistantTools.ToolError.accessChanged }
                return prepare(event: event, accountID: key.accountID, calendarID: key.calendarID, sourceEvent: original)
            },
            workingHours: { [weak self] in self?.workingHours ?? CalendarWorkingHours() },
            prepareDeletion: { [weak self] key, event in
                guard let self, assistantScope.allows(key, details: true), calendars.contains(where: {
                    $0.accountID == key.accountID && $0.calendarID == key.calendarID && $0.canWrite
                }) else { throw CalendarAssistantTools.ToolError.accessChanged }
                return prepareDeletion(event: event, accountID: key.accountID, calendarID: key.calendarID)
            }
        )
    }
}
