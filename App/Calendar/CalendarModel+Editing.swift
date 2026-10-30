import Foundation
import GmailAPI
import MailStore
import SyncEngine

extension CalendarModel {
    func beginNew(on start: Date) {
        beginNew(in: CalendarEventRange(start: start, end: start.addingTimeInterval(1800), isAllDay: false))
    }

    func edit(_ display: CalendarDisplayEvent) { edit(display, proposedEvent: nil) }

    func edit(_ display: CalendarDisplayEvent, proposedEvent: GoogleCalendarEvent?) {
        var display = display
        display.canEdit = display.canEdit && calendars.first(where: { $0.id == display.calendarKey })
            .map { CalendarEventPermissions.canEdit(display.event, in: $0) } == true
            && !operations.contains(where: { CalendarPendingEvents.blocksEditing($0, event: display) })
        selectedEventID = display.id
        editRevision += 1
        let revision = editRevision
        guard display.isRecurring else {
            editor = CalendarEditorDraft(event: proposedEvent ?? display.event, calendarKey: display.calendarKey, source: display)
            return
        }
        Task {
            do {
                guard let engine = engines[display.accountID] else { throw CalendarModelError.unavailable }
                let id = display.event.recurringEventId ?? display.event.id
                let master = try await engine.readEvent(calendarID: display.calendarID, eventID: id, refresh: false)
                guard revision == editRevision else { return }
                var source = display
                source.event.recurrence = master.recurrence
                var proposed = proposedEvent ?? source.event
                proposed.recurrence = source.event.recurrence
                var draft = CalendarEditorDraft(event: proposed, calendarKey: source.calendarKey, source: source)
                draft.seriesMaster = master
                draft.additionalNotificationRecipients = (master.attendees ?? []).map(\.email)
                editor = draft
                await loadSeriesReview(draftID: draft.id, source: source, masterID: id)
            } catch {
                guard revision == editRevision else { return }
                // A cached occurrence can still be changed offline. Series-wide
                // options require the master and its reviewed version.
                var draft = CalendarEditorDraft(event: proposedEvent ?? display.event, calendarKey: display.calendarKey, source: display)
                if display.event.recurrence?.isEmpty == false { draft.seriesMaster = display.event }
                editor = draft
                statusText = "Showing the cached occurrence. Series details could not refresh."
            }
        }
    }

    func loadSeriesReview(draftID: UUID, source: CalendarDisplayEvent, masterID: String) async {
        let revision = lifecycleRevision
        guard let engine = engines[source.accountID] else { return }
        do {
            let exceptions = try await engine.futureExceptions(calendarID: source.calendarID, eventID: masterID, from: .distantPast)
            guard revision == lifecycleRevision, editor?.id == draftID else { return }
            let start = source.event.originalStartTime?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? source.start
            editor?.followingExceptionsCount = exceptions.filter {
                ($0.originalStartTime?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? .distantPast) >= start
            }.count
            editor?.additionalNotificationRecipients += exceptions.flatMap { ($0.attendees ?? []).map(\.email) }
        } catch {
            if revision == lifecycleRevision, editor?.id == draftID { statusText = "Future exceptions could not be checked. Refresh before changing following events." }
        }
    }

    func duplicate(_ display: CalendarDisplayEvent) {
        guard let owner = calendars.first(where: { $0.id == display.calendarKey && $0.canWrite })
                ?? calendars.first(where: { $0.canWrite && $0.isVisible }) ?? calendars.first(where: \.canWrite) else {
            errorMessage = "Connect a writable Google calendar before adding an event."; return
        }
        var event = display.event
        for key in ["id", "etag", "iCalUID", "created", "updated", "organizer", "creator", "recurringEventId", "originalStartTime", "recurrence", "conferenceData", "hangoutLink", "locked"] {
            event.rawValue[key] = nil
        }
        event.attendees = nil
        event.eventType = nil
        for key in ["birthdayProperties", "outOfOfficeProperties", "focusTimeProperties", "workingLocationProperties"] {
            event.rawValue[key] = nil
        }
        editRevision += 1
        editor = CalendarEditorDraft(event: event, calendarKey: owner.id)
    }

    func save(_ draft: CalendarEditorDraft) async throws {
        if savedDraftOperations[draft.id] != nil {
            if editor?.id == draft.id { editor = nil }
            await reloadOperations(); return
        }
        guard savingDrafts.insert(draft.id).inserted else { return }
        defer { savingDrafts.remove(draft.id) }
        if let source = draft.source, !savingEvents.insert(source.id).inserted {
            throw CalendarModelError.unsupported("This event is being saved. Wait for it to finish before changing it again.")
        }
        defer { if let source = draft.source { savingEvents.remove(source.id) } }
        guard let owner = calendars.first(where: { $0.id == draft.calendarKey }),
              let engine = engines[owner.accountID] else { throw CalendarModelError.unavailable }
        guard owner.canWrite else { throw CalendarModelError.readOnly }
        let revision = lifecycleRevision
        if let source = draft.source { try await validateMutationSource(source, replacing: draft.operationID) }
        var event = draft.event
        if let sourceID = draft.sourceID, let suggestion = try await store?.suggestion(id: sourceID), suggestion.accountID != owner.accountID {
            throw CalendarModelError.unsupported("Choose a calendar belonging to the source email account.")
        }
        guard (draft.source != nil || !(event.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              let start = event.start?.resolvedDate(fallbackTimeZone: calendar.timeZone),
              let end = event.end?.resolvedDate(fallbackTimeZone: calendar.timeZone), end > start,
              event.start?.isAllDay == event.end?.isAllDay else { throw CalendarModelError.invalidEvent }
        if draft.createMeet {
            guard owner.entry.supportsGoogleMeet else {
                throw CalendarModelError.unsupported("This calendar does not support creating Google Meet links.")
            }
            event.rawValue["conferenceData"] = .object(["createRequest": .object([
                "requestId": .string(UUID().uuidString.lowercased()),
                "conferenceSolutionKey": .object(["type": .string("hangoutsMeet")])
            ])])
        }
        let change: CalendarMutation
        var targetCalendarID = owner.calendarID
        var before: GoogleCalendarEvent?
        if draft.isDeletion {
            guard let source = draft.source, source.canEdit, source.accountID == owner.accountID,
                  source.calendarID == owner.calendarID else { throw CalendarModelError.readOnly }
            let target = draft.editScope == .occurrence ? source.event : draft.seriesMaster ?? source.event
            if draft.editScope == .following {
                guard let start = source.event.originalStartTime ?? source.event.start else { throw CalendarModelError.invalidEvent }
                change = .deleteFollowing(eventID: target.id, etag: target.etag, originalStart: start)
            } else { change = .delete(eventID: target.id, etag: target.etag) }
            if !source.isRecurring { before = source.event }
        } else if let source = draft.source {
            guard source.accountID == owner.accountID else {
                throw CalendarModelError.unsupported("Duplicate this event to move it to another Google account.")
            }
            guard source.canEdit else { throw CalendarModelError.readOnly }
            if source.calendarID != owner.calendarID {
                guard event.changedFields(from: source.event).isEmpty, !source.isRecurring else {
                    throw CalendarModelError.unsupported("Save other changes before moving a non-recurring event to another calendar.")
                }
                targetCalendarID = source.calendarID
                change = .move(eventID: source.event.id, destination: owner.calendarID, etag: source.event.etag)
            } else {
                if event.changedFields(from: source.event).isEmpty { editor = nil; return }
                change = try await mutation(for: event, source: source, scope: draft.editScope,
                    master: draft.seriesMaster, confirmedReset: draft.acknowledgesFollowingReset)
                if case .update = change { before = draft.editScope == .series ? draft.seriesMaster : source.event }
            }
        } else if draft.isImport {
            change = draft.importedExceptions.isEmpty ? .importEvent(event)
                : .importSeries(master: event, exceptions: draft.importedExceptions)
        } else {
            event.id = ""; event.iCalUID = nil
            change = .create(event)
        }
        guard revision == lifecycleRevision else { throw CalendarModelError.unavailable }
        let operation: CalendarOperation
        let reviewedSource = draft.editScope == .occurrence ? draft.source?.event : draft.seriesMaster
        if let previous = draft.operationID {
            operation = try await engine.revise(operationID: previous, mutation: change,
                calendarID: targetCalendarID, sendUpdates: draft.isImport ? "none" : "all", sourceSuggestionID: draft.sourceID,
                beforeEvent: reviewedSource)
        } else {
            operation = try await engine.enqueue(change, calendarID: targetCalendarID, sendUpdates: draft.isImport ? "none" : "all",
                sourceSuggestionID: draft.sourceID, beforeEvent: reviewedSource)
        }
        // A durable queue receipt is success for this editor. Foreground network
        // failure must never leave a second Save capable of duplicating the event.
        savedDraftOperations[draft.id] = operation.id
        if editor?.id == draft.id { editor = nil }
        proposedEditors[draft.id] = nil
        if case .create = change {
            undoActions.append(CalendarUndoAction(operationID: operation.id, accountID: owner.accountID, calendarID: targetCalendarID))
        } else if let before {
            undoActions.append(CalendarUndoAction(operationID: operation.id, accountID: owner.accountID, calendarID: targetCalendarID, before: before))
        }
        if let sourceID = draft.sourceID {
            do { try await recordAcceptedSuggestion(sourceID: sourceID, event: event, operation: operation) }
            catch { errorMessage = "The calendar change was queued, but its email link could not be saved." }
        }
        statusText = "Calendar change queued."
        await reloadOperations()
        projectPendingEvents()
        do { try await engine.flush() }
        catch { statusText = "Calendar change saved locally; waiting for a connection." }
        guard revision == lifecycleRevision else { return }
        await reloadOperations()
        if let saved = operations.first(where: { $0.id == operation.id }), saved.status == .failed || saved.status == .conflicted {
            errorMessage = saved.errorMessage ?? "The calendar change needs review in Calendar activity."
        }
        await reloadOccurrences(); await refreshNotifications()
    }

    private func mutation(for edited: GoogleCalendarEvent, source: CalendarDisplayEvent, scope: CalendarEditScope,
                          master baseline: GoogleCalendarEvent?, confirmedReset: Bool) async throws -> CalendarMutation {
        guard source.isRecurring, scope != .occurrence else {
            var fields = edited.changedFields(from: source.event)
            if source.isRecurring { fields["recurrence"] = nil }
            return .update(eventID: source.event.id, fields: fields, etag: source.event.etag)
        }
        let masterID = source.event.recurringEventId ?? source.event.id
        guard let master = baseline, master.id == masterID else { throw CalendarModelError.changed }
        if scope == .following {
            guard let original = source.event.originalStartTime ?? source.event.start else { throw CalendarModelError.invalidEvent }
            var following = master
            for (key, value) in edited.changedFields(from: source.event) { following.rawValue[key] = value == .null ? nil : value }
            following.start = edited.start; following.end = edited.end
            return .splitSeries(eventID: masterID, etag: master.etag, originalStart: original,
                followingEvent: following, resetExceptionsConfirmed: confirmedReset)
        }
        var fields = edited.changedFields(from: source.event)
        // Apply an occurrence's time change as an offset to the series anchor.
        for name in ["start", "end"] where fields[name] != nil {
            let old = name == "start" ? source.event.start : source.event.end
            let new = name == "start" ? edited.start : edited.end
            let anchor = name == "start" ? master.start : master.end
            if let oldDate = old?.resolvedDate(), let newDate = new?.resolvedDate(), let anchorDate = anchor?.resolvedDate() {
                let adjusted = CalendarDateTime(date: adjustSeriesAnchor(anchorDate, from: oldDate, to: newDate, timeZone: TimeZone(identifier: old?.timeZone ?? "") ?? calendar.timeZone),
                    timeZone: TimeZone(identifier: new?.timeZone ?? "") ?? calendar.timeZone, allDay: new?.isAllDay == true)
                fields[name] = try CalendarJSON.encoding(adjusted)
            }
        }
        return .update(eventID: masterID, fields: fields, etag: master.etag)
    }

    private func adjustSeriesAnchor(_ anchor: Date, from old: Date, to new: Date, timeZone: TimeZone) -> Date {
        var civil = Calendar(identifier: .gregorian); civil.timeZone = timeZone
        let difference = civil.dateComponents([.day, .hour, .minute, .second], from: old, to: new)
        return civil.date(byAdding: difference, to: anchor) ?? anchor
    }

    func delete(_ display: CalendarDisplayEvent, scope: CalendarEditScope = .occurrence) async throws {
        guard savingEvents.insert(display.id).inserted else {
            throw CalendarModelError.unsupported("This event is being saved. Wait for it to finish before changing it again.")
        }
        defer { savingEvents.remove(display.id) }
        try await validateMutationSource(display)
        guard display.canEdit, let engine = engines[display.accountID] else { throw CalendarModelError.readOnly }
        let id = scope == .occurrence ? display.event.id : display.event.recurringEventId ?? display.event.id
        let original = id == display.event.id ? display.event : try await engine.readEvent(calendarID: display.calendarID, eventID: id, refresh: true)
        if display.isRecurring, scope != .occurrence {
            let revision = lifecycleRevision
            let start = display.event.originalStartTime?.resolvedDate(fallbackTimeZone: calendar.timeZone) ?? display.start
            let exceptions = try await engine.futureExceptions(calendarID: display.calendarID, eventID: id, from: scope == .series ? .distantPast : start)
            guard revision == lifecycleRevision else { throw CalendarModelError.unavailable }
            var source = display
            source.event.recurrence = original.recurrence
            var draft = CalendarEditorDraft(event: source.event, calendarKey: display.calendarKey, source: source, editScope: scope)
            draft.seriesMaster = original; draft.isDeletion = true
            draft.followingExceptionsCount = exceptions.count
            draft.additionalNotificationRecipients = ((original.attendees ?? []) + exceptions.flatMap { $0.attendees ?? [] }).map(\.email)
            editor = draft
            return
        }
        let change: CalendarMutation
        if scope == .following {
            guard let start = display.event.originalStartTime ?? display.event.start else { throw CalendarModelError.invalidEvent }
            change = .deleteFollowing(eventID: id, etag: original.etag, originalStart: start)
        } else { change = .delete(eventID: id, etag: original.etag) }
        let operation = try await engine.enqueue(change, calendarID: display.calendarID, beforeEvent: original)
        if scope == .occurrence, !display.isRecurring {
            undoActions.append(CalendarUndoAction(operationID: operation.id, accountID: display.accountID,
                calendarID: display.calendarID, before: original))
        }
        await reloadOperations()
        projectPendingEvents()
        do { try await engine.flush() } catch { statusText = "Deletion queued; waiting for a connection." }
        await reloadOperations(); await reloadOccurrences(); await refreshNotifications()
    }

    func move(_ display: CalendarDisplayEvent, to start: Date) async throws {
        let range = CalendarInteraction.moving(display, to: start, calendar: calendar)
        let changed = range.applying(to: display.event, calendar: calendar)
        try await save(CalendarEditorDraft(event: changed, calendarKey: display.calendarKey, source: display))
    }

    func resize(_ display: CalendarDisplayEvent, end: Date) async throws {
        let range = CalendarEventRange(start: display.start, end: end, isAllDay: display.isAllDay)
        let changed = range.applying(to: display.event, calendar: calendar)
        try await save(CalendarEditorDraft(event: changed, calendarKey: display.calendarKey, source: display))
    }

    func undo() async {
        guard !isUndoing else { return }
        isUndoing = true
        defer { isUndoing = false }
        if let pending = operations.last(where: { $0.status == .queued && $0.attempts == 0 }), let engine = engines[pending.accountID] {
            do {
                try await engine.cancel(operationID: pending.id)
                undoActions.removeAll { $0.operationID == pending.id }
            } catch { errorMessage = error.localizedDescription }
            await reloadOperations(); await reloadOccurrences(); return
        }
        guard let action = undoActions.last,
              let operation = operations.first(where: { $0.id == action.operationID }), operation.status == .completed else { return }
        let recipients = Set(((operation.resultEvent?.attendees ?? []) + (action.before?.attendees ?? [])).map(\.email))
        if !recipients.isEmpty { undoConfirmation = recipients.sorted(); return }
        await performConfirmedUndo()
    }

    func cancelUndo() { undoConfirmation = nil }

    func confirmUndo() async {
        guard !isUndoing else { return }
        isUndoing = true
        defer { isUndoing = false }
        undoConfirmation = nil
        await performConfirmedUndo()
    }

    private func performConfirmedUndo() async {
        guard let action = undoActions.last, let engine = engines[action.accountID],
              let operation = operations.first(where: { $0.id == action.operationID }), operation.status == .completed else { return }
        do {
            let mutation: CalendarMutation
            switch operation.mutation {
            case .create:
                guard let result = operation.resultEvent, let etag = result.etag else { throw CalendarModelError.changed }
                mutation = .delete(eventID: result.id, etag: etag)
            case .update:
                guard let before = action.before, let result = operation.resultEvent, let etag = result.etag else { throw CalendarModelError.changed }
                mutation = .update(eventID: result.id, fields: before.changedFields(from: result), etag: etag)
            case .delete:
                guard var before = action.before else { throw CalendarModelError.changed }
                for key in ["id", "etag", "iCalUID", "status", "created", "updated", "organizer", "creator"] { before.rawValue[key] = nil }
                mutation = .create(before)
            default: throw CalendarModelError.unsupported("This change must be reversed by editing the event.")
            }
            _ = try await engine.enqueue(mutation, calendarID: action.calendarID, beforeEvent: operation.resultEvent)
            undoActions.removeAll { $0.operationID == action.operationID }
            await reloadOperations()
            projectPendingEvents()
            try await engine.flush()
        } catch { errorMessage = error.localizedDescription }
        await reloadOperations(); await reloadOccurrences(); await refreshNotifications()
    }
}
