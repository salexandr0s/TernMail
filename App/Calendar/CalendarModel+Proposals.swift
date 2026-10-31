import Foundation
import GmailAPI
import MailStore
import SyncEngine

extension CalendarModel {
    func readEvent(accountID: String, calendarID: String, eventID: String) async throws -> GoogleCalendarEvent {
        guard let engine = engines[accountID], calendars.contains(where: { $0.accountID == accountID && $0.calendarID == calendarID }) else {
            throw CalendarModelError.unavailable
        }
        do { return try await engine.readEvent(calendarID: calendarID, eventID: eventID, refresh: true) }
        catch { handleCalendarAccessFailure(error, accountID: accountID, calendarID: calendarID); throw error }
    }

    func queryEvents(accountID: String, calendarID: String, start: Date, end: Date) async throws -> CalendarOccurrenceResult {
        guard let engine = engines[accountID] else { throw CalendarModelError.unavailable }
        do { return try await engine.occurrences(calendarID: calendarID, start: start, end: end) }
        catch { handleCalendarAccessFailure(error, accountID: accountID, calendarID: calendarID); throw error }
    }

    func findAvailability(accountID: String, calendarIDs: [String], start: Date, end: Date,
                          hours: CalendarWorkingHours) async throws -> CalendarAvailabilityResult {
        guard let engine = engines[accountID] else { throw CalendarModelError.unavailable }
        return try await engine.availability(calendarIDs: calendarIDs, start: start, end: end, hours: hours)
    }

    func handleCalendarAccessFailure(_ error: any Error, accountID: String, calendarID: String) {
        let denied: Bool
        if let google = error as? GmailError {
            if case .http(status: 403, reason: _) = google { denied = true }
            else { denied = google == .unauthorized }
        } else { denied = error as? CalendarEngineError == .permissionDenied }
        guard denied else { return }
        let key = CalendarDisplayCalendar.key(accountID: accountID, calendarID: calendarID)
        calendars.removeAll { $0.id == key }
        events.removeAll { $0.calendarKey == key }
        searchResults.removeAll { $0.calendarKey == key }
        invalidateAssistantAccess()
        Task { await notifications.remove(accountID: accountID, calendarID: calendarID) }
    }

    func prepare(event: GoogleCalendarEvent, accountID: String, calendarID: String,
                 sourceEvent: GoogleCalendarEvent? = nil, isDeletion: Bool = false) -> UUID {
        let key = CalendarDisplayCalendar.key(accountID: accountID, calendarID: calendarID)
        let owner = calendars.first { $0.id == key }
        let source = sourceEvent.map { CalendarDisplayEvent(event: $0, accountID: accountID, calendarID: calendarID,
            canEdit: owner?.canWrite == true, fallbackTimeZoneID: calendar.timeZone.identifier) }
        var draft = CalendarEditorDraft(event: event, calendarKey: key, source: source)
        draft.isDeletion = isDeletion
        if let sourceEvent, sourceEvent.recurrence?.isEmpty == false { draft.seriesMaster = sourceEvent }
        let revision = accessRevision
        proposedEditors[draft.id] = draft
        proposalTasks[draft.id] = Task {
            defer { proposalTasks[draft.id] = nil }
            do {
                guard revision == accessRevision, owner?.aiAccess != .off, let engine = engines[accountID] else { throw CalendarModelError.unavailable }
                let mutation: CalendarMutation = if isDeletion, let sourceEvent {
                    .delete(eventID: sourceEvent.id, etag: sourceEvent.etag)
                } else if let sourceEvent {
                    .update(eventID: sourceEvent.id, fields: event.changedFields(from: sourceEvent), etag: sourceEvent.etag)
                } else { .create(event) }
                let operation = try await engine.propose(mutation, calendarID: calendarID)
                guard revision == accessRevision, proposedEditors[draft.id] != nil else {
                    try? await engine.cancel(operationID: operation.id); return
                }
                proposedEditors[draft.id]?.operationID = operation.id
                await reloadOperations()
                if revision != accessRevision || proposedEditors[draft.id] == nil {
                    _ = try? await store?.cancelOperation(accountID: accountID, id: operation.id)
                }
            } catch {
                proposedEditors[draft.id] = nil
                if revision == accessRevision { errorMessage = "Could not retain this calendar proposal: \(error.localizedDescription)" }
            }
        }
        return draft.id
    }

    func prepareDeletion(event: GoogleCalendarEvent, accountID: String, calendarID: String) -> UUID {
        prepare(event: event, accountID: accountID, calendarID: calendarID, sourceEvent: event, isDeletion: true)
    }

    func openProposal(_ id: UUID) {
        Task {
            await proposalTasks[id]?.value
            guard var draft = proposedEditors[id], let owner = calendars.first(where: { $0.id == draft.calendarKey }),
                  owner.aiAccess != .off, owner.canWrite, draft.operationID != nil else { return }
            let revision = accessRevision
            if let source = draft.source, source.isRecurring, draft.seriesMaster == nil {
                do {
                    let master = try await readEvent(accountID: owner.accountID, calendarID: owner.calendarID,
                        eventID: source.event.recurringEventId ?? source.event.id)
                    guard revision == accessRevision else { return }
                    draft.seriesMaster = master
                    draft.additionalNotificationRecipients = (master.attendees ?? []).map(\.email)
                    var sourceEvent = source.event
                    sourceEvent.recurrence = master.recurrence
                    draft.source = source.replacingEvent(sourceEvent)
                    draft.event.recurrence = master.recurrence
                } catch { errorMessage = error.localizedDescription; return }
            }
            guard revision == accessRevision else { return }
            editor = draft
            app?.showCalendar()
            if let source = draft.source, source.isRecurring {
                await loadSeriesReview(draftID: draft.id, source: source, masterID: source.event.recurringEventId ?? source.event.id)
            }
        }
    }

    func openEvent(accountID: String, calendarID: String, eventID: String) async {
        do {
            let event = try await readEvent(accountID: accountID, calendarID: calendarID, eventID: eventID)
            guard let owner = calendars.first(where: { $0.accountID == accountID && $0.calendarID == calendarID }) else { return }
            date = event.start?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? date
            app?.showCalendar()
            edit(CalendarDisplayEvent(event: event, accountID: accountID, calendarID: calendarID,
                colorHex: owner.colorHex, canEdit: owner.canWrite, fallbackTimeZoneID: calendar.timeZone.identifier))
        } catch { errorMessage = error.localizedDescription }
    }

    func exportCalendar(_ owner: CalendarDisplayCalendar) async throws -> [GoogleCalendarEvent] {
        guard owner.entry.canReadDetails, let engine = engines[owner.accountID], let store else { throw CalendarModelError.unavailable }
        let revision = lifecycleRevision
        try await engine.syncEvents(calendarID: owner.calendarID)
        guard revision == lifecycleRevision else { throw CalendarModelError.unavailable }
        return try await store.events(accountID: owner.accountID, calendarID: owner.calendarID)
    }

    func reviewOperation(_ operation: CalendarOperation) {
        guard let owner = calendars.first(where: { $0.accountID == operation.accountID && $0.calendarID == operation.calendarID }) else { return }
        // Proposed assistant content is unavailable when its calendar permission
        // has been revoked, including proposals retained across launches.
        if operation.status == .proposed, owner.aiAccess == .off { return }
        let scopeRevision = accessRevision
        Task {
            do {
                let revision = lifecycleRevision
                var draft: CalendarEditorDraft
                switch operation.mutation {
                case .create(let event):
                    draft = CalendarEditorDraft(event: event, calendarKey: owner.id)
                case .importEvent(let event):
                    draft = CalendarEditorDraft(event: event, calendarKey: owner.id, isImport: true)
                case .importSeries(let master, let exceptions):
                    draft = CalendarEditorDraft(event: master, calendarKey: owner.id, isImport: true, importedExceptions: exceptions)
                case .delete(let id, _):
                    let current = try await readEvent(accountID: owner.accountID, calendarID: owner.calendarID, eventID: id)
                    let source = CalendarDisplayEvent(event: current, accountID: owner.accountID, calendarID: owner.calendarID,
                        canEdit: owner.canWrite, fallbackTimeZoneID: calendar.timeZone.identifier)
                    draft = CalendarEditorDraft(event: current, calendarKey: owner.id, source: source)
                    draft.isDeletion = true
                    if current.recurrence?.isEmpty == false { draft.seriesMaster = current; draft.editScope = .series }
                case .update(let id, let fields, _):
                    let current = try await readEvent(accountID: owner.accountID, calendarID: owner.calendarID, eventID: id)
                    var edited = current
                    for (key, value) in fields { edited.rawValue[key] = value == .null ? nil : value }
                    let source = CalendarDisplayEvent(event: current, accountID: owner.accountID, calendarID: owner.calendarID,
                        canEdit: owner.canWrite, fallbackTimeZoneID: calendar.timeZone.identifier)
                    draft = CalendarEditorDraft(event: edited, calendarKey: owner.id, source: source)
                    if current.recurrence?.isEmpty == false { draft.seriesMaster = current; draft.editScope = .series }
                default:
                    // Partly completed multi-step actions retain their original
                    // checkpoint and may only resume through the queue.
                    errorMessage = operation.errorMessage ?? "Use Retry to resume this calendar operation."
                    return
                }
                guard revision == lifecycleRevision, scopeRevision == accessRevision,
                      calendars.contains(where: { $0.id == owner.id && $0.canWrite }),
                      let currentOperation = try await store?.operation(accountID: operation.accountID, id: operation.id),
                      currentOperation.status == operation.status else { return }
                guard revision == lifecycleRevision, scopeRevision == accessRevision else { return }
                draft.operationID = operation.id
                editor = draft
                app?.showCalendar()
                if let source = draft.source, source.isRecurring {
                    await loadSeriesReview(draftID: draft.id, source: source, masterID: source.event.recurringEventId ?? source.event.id)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func retryOperation(_ operation: CalendarOperation) async {
        guard let engine = engines[operation.accountID] else { return }
        if operation.status == .conflicted { reviewOperation(operation); return }
        do { try await engine.retry(operationID: operation.id); try await engine.flush() }
        catch { errorMessage = error.localizedDescription }
        await reloadOperations(); await reloadOccurrences(); await refreshNotifications()
    }

    func cancelOperation(_ operation: CalendarOperation) async {
        guard let engine = engines[operation.accountID] else { return }
        do {
            try await engine.cancel(operationID: operation.id)
            undoActions.removeAll { $0.operationID == operation.id }
        } catch { errorMessage = error.localizedDescription }
        await reloadOperations(); await reloadOccurrences()
    }
}
