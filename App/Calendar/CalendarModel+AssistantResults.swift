import Foundation
import GmailAPI
import MailStore

extension CalendarModel {
    /// Opens a user-owned editor; presentation tools never call this or save an event.
    func reviewAssistantEvent(_ result: AssistantEventResult,
                              isAuthorized: @escaping @MainActor () -> Bool) async throws {
        let revision = lifecycleRevision
        func check() throws {
            try Task.checkCancellation()
            guard revision == lifecycleRevision, isAuthorized() else { throw AssistantError.accessChanged }
        }
        try check()
        let actionKey = "assistant-result:" + result.id
        guard interactionsInFlight.insert(actionKey).inserted else { return }
        defer { interactionsInFlight.remove(actionKey) }

        if case .calendar(let calendarID, let eventID) = result.source.target {
            try await openAssistantResultEvent(accountID: result.source.accountID, calendarID: calendarID,
                eventID: eventID, validate: check)
            return
        }
        guard result.canAddToCalendar, let store else { throw CalendarModelError.invalidEvent }
        let accountID = result.source.accountID
        let sourceID = accountID + ":" + result.id
        if editor?.sourceID == sourceID { return }
        var saved = try await store.suggestion(id: sourceID)
        try check()
        if let operationID = saved?.operationID {
            guard let operation = try await store.operation(accountID: accountID, id: operationID) else {
                throw CalendarModelError.unsupported("The earlier calendar action could not be found. Check Calendar before adding this event again.")
            }
            try check()
            if operation.status == .completed, let eventID = operation.resultEvent?.id ?? operation.mutation.eventID {
                try await openAssistantResultEvent(accountID: accountID, calendarID: operation.calendarID,
                    eventID: eventID, validate: check)
                return
            }
            if operation.status != .cancelled {
                guard let owner = calendars.first(where: { $0.accountID == accountID && $0.calendarID == operation.calendarID && $0.canWrite }),
                      case .create(let event) = operation.mutation else {
                    throw CalendarModelError.unsupported("Review the earlier calendar action in Calendar activity.")
                }
                var draft = CalendarEditorDraft(event: event, calendarKey: owner.id)
                draft.sourceID = sourceID
                draft.operationID = operation.id
                draft.sourceTitle = "This event already has a calendar action. Review that action before saving changes."
                editor = draft
                app?.showCalendar()
                return
            }
        }
        guard let owner = calendars.first(where: { $0.accountID == accountID && $0.canWrite && $0.isVisible })
            ?? calendars.first(where: { $0.accountID == accountID && $0.canWrite }) else {
            throw CalendarModelError.unsupported("Connect a writable calendar for this Google account before adding an event.")
        }
        let record = CalendarSuggestionRecord(id: sourceID, accountID: accountID,
            threadID: result.source.threadID, messageID: result.emailItem.messageID,
            sourceRevision: result.id, event: result.event, sourceText: result.evidence ?? "")
        try await store.saveSuggestion(record)
        try check()
        saved = try await store.suggestion(id: sourceID)
        try check()
        guard let retained = saved, retained.accountID == accountID,
              calendars.contains(where: { $0.id == owner.id && $0.canWrite }) else { throw CalendarModelError.unavailable }
        if editor?.sourceID == sourceID { return }
        var event = retained.isUserEdited ? retained.event : result.event
        guard let start = event.start?.resolvedDate(fallbackTimeZone: calendar.timeZone) else { throw CalendarModelError.invalidEvent }
        if event.end == nil {
            let end = event.isAllDay ? calendar.date(byAdding: .day, value: 1, to: start) : start.addingTimeInterval(1800)
            guard let end else { throw CalendarModelError.invalidEvent }
            event.end = CalendarDateTime(date: end, timeZone: calendar.timeZone, allDay: event.isAllDay)
        }
        var draft = CalendarEditorDraft(event: event, calendarKey: owner.id)
        draft.sourceID = sourceID
        draft.sourceTitle = "From email. Review the date, time zone and duration (30 minutes when unspecified)."
        editor = draft
        app?.showCalendar()
    }

    private func openAssistantResultEvent(accountID: String, calendarID: String, eventID: String,
                                          validate: () throws -> Void) async throws {
        let event = try await readEvent(accountID: accountID, calendarID: calendarID, eventID: eventID)
        try validate()
        guard !event.isCancelled, let owner = calendars.first(where: {
            $0.accountID == accountID && $0.calendarID == calendarID && $0.entry.canReadDetails
        }) else { throw CalendarModelError.unavailable }
        date = event.start?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? date
        edit(CalendarDisplayEvent(event: event, accountID: accountID, calendarID: calendarID,
            colorHex: owner.colorHex, canEdit: owner.canWrite, fallbackTimeZoneID: calendar.timeZone.identifier))
        app?.showCalendar()
    }
}
