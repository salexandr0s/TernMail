import Foundation
import GmailAPI
import MailStore
import MessageContent
import SyncEngine

struct EmailCalendarResponseReview: Identifiable {
    enum Delivery {
        case google(calendarID: String, eventID: String)
        case email
    }
    let id = UUID()
    let item: EmailCalendarItem
    let answer: InvitationReply.Answer
    let delivery: Delivery
    let explanation: String
}

extension CalendarModel {
    func interpretEmailSuggestions(_ model: EmailCalendarModel, key: ThreadKey, service: EmailCalendarExtractionService) async {
        let revision = lifecycleRevision
        let sourceRevision = model.revision
        do {
            var restored = false
            if let cached = try await store?.emailInterpretation(accountID: key.accountID, threadID: key.threadID, revision: sourceRevision) {
                try validateEmailLifetime(revision, accountID: key.accountID)
                guard service.isScopeValid() else { model.clearAIResults(); return }
                if let decoded = try? JSONDecoder().decode([EmailCalendarItem].self, from: cached) {
                    restored = model.restoreInterpretation(decoded, for: sourceRevision)
                }
            }
            if !restored { await model.interpret(using: service) }
            try validateEmailLifetime(revision, accountID: key.accountID)
            guard service.isScopeValid(), sourceRevision == model.revision else { model.clearAIResults(); return }
            if !restored, let results = model.cachedInterpretation {
                try await store?.saveEmailInterpretation(JSONEncoder().encode(results), accountID: key.accountID,
                    threadID: key.threadID, revision: sourceRevision)
            }
            try validateEmailLifetime(revision, accountID: key.accountID)
            guard service.isScopeValid() else { model.clearAIResults(); return }
            try await persistEmailSuggestions(model, key: key)
            await matchEmailSuggestions(model, key: key)
        } catch is CancellationError {
        } catch { errorMessage = "Calendar interpretation could not be retained locally." }
    }

    func observeEmailSuggestions(_ model: EmailCalendarModel, detail: ThreadDetail, key: ThreadKey) async {
        guard let cache = app?.cache else { return }
        do {
            for try await state in cache.calendarInvitationState(accountID: key.accountID) {
                try Task.checkCancellation()
                await loadEmailSuggestions(model, detail: detail, key: key, invitationState: state)
            }
        } catch is CancellationError {
        } catch { errorMessage = "Calendar invitations could not be refreshed." }
    }

    func loadEmailSuggestions(_ model: EmailCalendarModel, detail: ThreadDetail, key: ThreadKey,
                              invitationState: CalendarInvitationState? = nil) async {
        let revision = lifecycleRevision
        guard let owner = app?.mailbox?.account(id: key.accountID), let cache = app?.cache else { return }
        let preparation = model.beginPreparation()
        let timeZone = calendar.timeZone
        let replyEngine = owner.engine
        let suggestionStore = store
        do {
            async let replyAddresses = replyEngine.calendarReplyAddresses()
            async let savedSuggestions = suggestionStore?.suggestions(accountID: key.accountID, threadID: key.threadID) ?? []
            let state: CalendarInvitationState
            if let invitationState { state = invitationState }
            else { state = try await cache.read { try $0.calendarInvitationState(accountID: key.accountID) } }
            try validateEmailLifetime(revision, accountID: key.accountID)
            let prepared = try await EmailCalendarPreparation.shared.prepare(detail: detail, invitations: state.invitations, accountID: key.accountID,
                lifetime: String(describing: ObjectIdentifier(owner)) + ":\(revision)", timeZone: timeZone)
            let (addresses, saved) = try await (replyAddresses, savedSuggestions)
            try validateEmailLifetime(revision, accountID: key.accountID)
            guard model.acceptsPreparation(preparation), calendar.timeZone == timeZone,
                  app?.mailbox?.account(id: key.accountID) === owner else { return }
            let prefix = key.accountID + ":"
            model.update(prepared: prepared, addresses: addresses, timeZone: timeZone,
                dismissedIDs: Set(saved.filter(\.isDismissed).map { String($0.id.dropFirst(prefix.count)) }), invitationState: state)
            for record in saved where record.isUserEdited {
                model.restoreCorrection(itemID: String(record.id.dropFirst(prefix.count)), event: record.event)
            }
            try await persistEmailSuggestions(model, key: key)
            await matchEmailSuggestions(model, key: key)
        } catch is CancellationError {
        } catch { errorMessage = "Calendar suggestions could not be refreshed." }
    }

    func persistEmailSuggestions(_ model: EmailCalendarModel, key: ThreadKey) async throws {
        let revision = lifecycleRevision
        let sourceRevision = model.revision
        guard let store else { return }
        for item in model.items {
            let saved = try await store.suggestion(id: key.accountID + ":" + item.id)
            try validateEmailLifetime(revision, accountID: key.accountID)
            guard model.revision == sourceRevision else { throw CancellationError() }
            if let saved, saved.isUserEdited {
                model.restoreCorrection(itemID: item.id, event: saved.event)
                continue
            }
            let event = item.event ?? GoogleCalendarEvent(summary: item.title)
            if let saved, saved.sourceRevision == sourceRevision, saved.event == event, saved.sourceText == item.evidence { continue }
            try await store.saveSuggestion(CalendarSuggestionRecord(id: key.accountID + ":" + item.id,
                accountID: key.accountID, threadID: key.threadID, messageID: item.messageID,
                sourceRevision: sourceRevision, event: event, sourceText: item.evidence))
        }
    }

    func dismissEmailSuggestion(_ id: String, key: ThreadKey) async {
        let revision = lifecycleRevision
        do {
            guard var record = try await store?.suggestion(id: key.accountID + ":" + id) else { return }
            record.isDismissed = true
            try validateEmailLifetime(revision, accountID: key.accountID)
            try await store?.saveSuggestion(record, preservingCorrections: false)
        } catch { errorMessage = "Could not remember this dismissed suggestion." }
    }

    func matchEmailSuggestions(_ model: EmailCalendarModel, key: ThreadKey) async {
        let revision = lifecycleRevision
        let sourceRevision = model.revision
        for item in model.items where !item.isOutdated {
            do {
                if let invitation = item.invitation, let match = try await emailInvitationMatch(invitation, accountID: key.accountID) {
                    try validateEmailLifetime(revision, accountID: key.accountID)
                    guard sourceRevision == model.revision else { return }
                    model.markExisting(itemID: item.id, calendarID: match.calendarID, eventID: match.event.id,
                        hasNewerInvitation: Self.isNewer(invitation, than: match.event),
                        calendarAnswer: match.event.attendees?.first(where: { $0.isSelf == true })?.responseStatus.flatMap {
                            Invitation.ParticipationStatus(rawValue: $0 == "needsAction" ? "NEEDS-ACTION" : $0.uppercased())
                        })
                } else if item.invitation == nil, !item.relatedMessageIDs.isEmpty {
                    do {
                        if let match = try await relatedEmailEvent(item, key: key) {
                            try validateEmailLifetime(revision, accountID: key.accountID)
                            guard sourceRevision == model.revision else { return }
                            model.markExisting(itemID: item.id, calendarID: match.calendarID, eventID: match.event.id, hasNewerInvitation: true)
                        }
                    } catch EmailCalendarLinkError.ambiguous {
                        model.markAmbiguous(itemID: item.id)
                    }
                } else if let record = try await store?.suggestion(id: key.accountID + ":" + item.id),
                          let operationID = record.operationID,
                          let operation = try await store?.operation(id: operationID),
                          operation.status == .completed,
                          let eventID = operation.resultEvent?.id ?? operation.mutation.eventID {
                    try validateEmailLifetime(revision, accountID: key.accountID)
                    guard sourceRevision == model.revision else { return }
                    model.markExisting(itemID: item.id, calendarID: operation.calendarID, eventID: eventID)
                }
            } catch is CancellationError { return }
            catch { /* Creation and RSVP recheck, and report a failed check before writing. */ }
        }
    }

    func reviewEmailSuggestion(_ item: EmailCalendarItem, key: ThreadKey) async {
        let revision = lifecycleRevision
        do {
            guard item.canReview, let store else { throw CalendarModelError.unavailable }
            if item.invitation == nil, let match = try await relatedEmailEvent(item, key: key) {
                guard let owner = calendars.first(where: { $0.accountID == key.accountID && $0.calendarID == match.calendarID }) else { throw CalendarModelError.unavailable }
                var edited = match.event
                for field in ["summary", "start", "end", "location", "description"] {
                    if let value = item.event?.rawValue[field] { edited.rawValue[field] = value }
                }
                try validateEmailLifetime(revision, accountID: key.accountID)
                var draft = CalendarEditorDraft(event: edited, calendarKey: owner.id,
                    source: CalendarDisplayEvent(event: match.event, accountID: key.accountID, calendarID: match.calendarID,
                        colorHex: owner.colorHex, canEdit: owner.canWrite))
                draft.sourceID = key.accountID + ":" + item.id
                draft.sourceTitle = "A later email proposes changes to this linked event. Review before saving."
                editor = draft
                app?.showCalendar()
                return
            }
            if let invitation = item.invitation, let match = try await emailInvitationMatch(invitation, accountID: key.accountID),
               Self.isNewer(invitation, than: match.event), !invitation.isCancelled {
                try validateEmailLifetime(revision, accountID: key.accountID)
                guard let owner = calendars.first(where: { $0.accountID == key.accountID && $0.calendarID == match.calendarID }) else { throw CalendarModelError.unavailable }
                let changes = invitation.recurrenceKey.isEmpty
                    ? try CalendarInterchange.googleEvent(from: invitation, fallbackTimeZone: calendar.timeZone)
                    : try CalendarInterchange.googleException(from: invitation, parentEventID: match.event.recurringEventId ?? match.event.id, fallbackTimeZone: calendar.timeZone)
                var edited = match.event
                // Copy invitation fields only. Preserve conference data, unknown fields and every attendee's Google response.
                for field in ["summary", "description", "location", "start", "end", "recurrence", "status", "sequence", "source"] {
                    if let value = changes.rawValue[field] { edited.rawValue[field] = value }
                }
                var draft = CalendarEditorDraft(event: edited, calendarKey: owner.id,
                    source: CalendarDisplayEvent(event: match.event, accountID: key.accountID, calendarID: match.calendarID,
                        colorHex: owner.colorHex, canEdit: owner.canWrite))
                draft.sourceID = key.accountID + ":" + item.id
                draft.sourceTitle = "Newer invitation from email. Review these proposed changes before saving."
                editor = draft
                app?.showCalendar()
                return
            }
            if let saved = try await store.suggestion(id: key.accountID + ":" + item.id), let id = saved.operationID,
               let operation = try await store.operation(id: id), operation.status != .cancelled {
                try validateEmailLifetime(revision, accountID: key.accountID)
                if let eventID = operation.resultEvent?.id ?? operation.mutation.eventID, operation.status == .completed {
                    await openEvent(accountID: operation.accountID, calendarID: operation.calendarID, eventID: eventID)
                } else { reviewOperation(operation) }
                return
            }
            if let invitation = item.invitation, let match = try await emailInvitationMatch(invitation, accountID: key.accountID) {
                try validateEmailLifetime(revision, accountID: key.accountID)
                await openEvent(accountID: key.accountID, calendarID: match.calendarID, eventID: match.event.id)
                return
            }
            guard let owner = calendars.first(where: { $0.accountID == key.accountID && $0.canWrite && $0.isVisible })
                    ?? calendars.first(where: { $0.accountID == key.accountID && $0.canWrite }) else {
                throw CalendarModelError.unsupported("Connect a writable calendar for this Google account before adding an event.")
            }
            var event: GoogleCalendarEvent
            if let invitation = item.invitation {
                // A personal copy is intentionally private: it neither accepts nor invites anyone.
                event = try CalendarInterchange.googleEvent(from: invitation, fallbackTimeZone: calendar.timeZone)
                event.attendees = nil
                event.organizer = nil
                event.rawValue["guestsCanInviteOthers"] = .bool(false)
            } else { event = item.event ?? GoogleCalendarEvent(summary: item.title) }
            if event.start == nil { event.start = CalendarDateTime(date: date, timeZone: calendar.timeZone) }
            if event.end == nil, let start = event.startDate {
                let end = event.isAllDay ? calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400) : start.addingTimeInterval(1800)
                event.end = CalendarDateTime(date: end, timeZone: calendar.timeZone, allDay: event.isAllDay)
            }
            var draft = CalendarEditorDraft(event: event, calendarKey: owner.id, isImport: item.invitation != nil)
            draft.sourceID = key.accountID + ":" + item.id
            draft.sourceTitle = item.invitation == nil ? "From email. Review the date, time zone and duration (30 minutes when unspecified)." : "Personal copy. This does not send an invitation response."
            try validateEmailLifetime(revision, accountID: key.accountID)
            editor = draft
            app?.showCalendar()
        } catch { errorMessage = error.localizedDescription }
    }

    func recordAcceptedSuggestion(sourceID: String, event: GoogleCalendarEvent, operation: CalendarOperation) async throws {
        let revision = lifecycleRevision
        guard let store, var suggestion = try await store.suggestion(id: sourceID) else { return }
        try validateEmailLifetime(revision, accountID: suggestion.accountID)
        let acceptedEvent = operation.resultEvent ?? (operation.sourceSuggestionID == sourceID ? suggestion.event : event)
        suggestion.event = acceptedEvent
        suggestion.isUserEdited = true
        suggestion.operationID = operation.id
        try await store.saveSuggestion(suggestion, preservingCorrections: false)
        if let eventID = operation.resultEvent?.id ?? operation.mutation.eventID {
            try validateEmailLifetime(revision, accountID: suggestion.accountID)
            try await store.saveSourceLink(CalendarSourceLink(id: sourceID, accountID: operation.accountID,
                calendarID: operation.calendarID, eventID: eventID, threadID: suggestion.threadID,
                messageID: suggestion.messageID, invitationUID: acceptedEvent.iCalUID))
        }
    }

    func reconcileEmailSourceLinks() async {
        let revision = lifecycleRevision
        guard let store else { return }
        for owner in app?.mailbox?.accounts ?? [] {
            do {
                for suggestion in try await store.acceptedEmailSuggestions(accountID: owner.account.id) {
                    try validateEmailLifetime(revision, accountID: owner.account.id)
                    guard let operationID = suggestion.operationID,
                          let operation = operations.first(where: { $0.id == operationID }),
                          let event = operation.resultEvent, operation.status == .completed else { continue }
                    try await recordAcceptedSuggestion(sourceID: suggestion.id, event: event, operation: operation)
                }
            } catch { errorMessage = "Some calendar links to source emails are waiting to save." }
        }
    }

    func emailCancellationEvent(_ item: EmailCalendarItem, key: ThreadKey) async throws -> CalendarDisplayEvent {
        let revision = lifecycleRevision
        if item.invitation == nil, item.kind == .cancelled, let match = try await relatedEmailEvent(item, key: key),
           let owner = calendars.first(where: { $0.accountID == key.accountID && $0.calendarID == match.calendarID }) {
            try validateEmailLifetime(revision, accountID: key.accountID)
            return CalendarDisplayEvent(event: match.event, accountID: key.accountID, calendarID: match.calendarID,
                colorHex: owner.colorHex, canEdit: owner.canWrite)
        }
        guard let invitation = item.invitation, invitation.isCancelled, !item.isOutdated,
              let match = try await emailInvitationMatch(invitation, accountID: key.accountID),
              Self.isNewer(invitation, than: match.event),
              let owner = calendars.first(where: { $0.accountID == key.accountID && $0.calendarID == match.calendarID }) else {
            throw CalendarModelError.unsupported("This cancellation is older than the current calendar event or has already been applied.")
        }
        try validateEmailLifetime(revision, accountID: key.accountID)
        return CalendarDisplayEvent(event: match.event, accountID: key.accountID, calendarID: match.calendarID,
            colorHex: owner.colorHex, canEdit: owner.canWrite)
    }

    private func relatedEmailEvent(_ item: EmailCalendarItem, key: ThreadKey) async throws -> (calendarID: String, event: GoogleCalendarEvent)? {
        guard !item.relatedMessageIDs.isEmpty, let store else { return nil }
        let revision = lifecycleRevision
        let related = Set(item.relatedMessageIDs)
        let links = try await store.sourceLinks(accountID: key.accountID).filter {
            $0.threadID == key.threadID && related.contains($0.messageID)
        }
        var targets = Set(links.map { EmailCalendarTarget(calendarID: $0.calendarID, eventID: $0.eventID) })
        let saved = try await store.suggestions(accountID: key.accountID, threadID: key.threadID)
        for source in saved where related.contains(source.messageID) {
            guard let id = source.operationID, let operation = try await store.operation(id: id), operation.status != .cancelled else { continue }
            guard operation.status == .completed, let eventID = operation.resultEvent?.id else {
                throw CalendarModelError.unsupported("An earlier calendar change for this conversation is still pending. Review Calendar activity first.")
            }
            targets.insert(EmailCalendarTarget(calendarID: operation.calendarID, eventID: eventID))
        }
        try validateEmailLifetime(revision, accountID: key.accountID)
        guard targets.count <= 1 else { throw EmailCalendarLinkError.ambiguous }
        guard let target = targets.first else { return nil }
        let event = try await readEvent(accountID: key.accountID, calendarID: target.calendarID, eventID: target.eventID)
        try validateEmailLifetime(revision, accountID: key.accountID)
        guard !event.isCancelled else { throw CalendarModelError.unsupported("The linked event has already been cancelled.") }
        return (target.calendarID, event)
    }
}

private struct EmailCalendarTarget: Hashable { let calendarID: String; let eventID: String }
private enum EmailCalendarLinkError: Error, LocalizedError {
    case ambiguous
    var errorDescription: String? { "Several saved events match this correction. Open Calendar to choose the intended event." }
}

extension CalendarModel {
    /// A conversation dropped on the grid. The editor opens prefilled from the
    /// email at the slot where it landed; nothing is saved until the user does.
    func beginNew(from link: MailLink, in range: CalendarEventRange) async {
        guard range.start.timeIntervalSinceReferenceDate.isFinite,
              range.end.timeIntervalSinceReferenceDate.isFinite, range.end > range.start else {
            errorMessage = CalendarModelError.invalidEvent.localizedDescription; return
        }
        guard let owner = calendars.first(where: { $0.accountID == link.accountID && $0.canWrite && $0.isVisible })
                ?? calendars.first(where: { $0.accountID == link.accountID && $0.canWrite })
                ?? calendars.first(where: { $0.canWrite && $0.isVisible }) ?? calendars.first(where: \.canWrite) else {
            errorMessage = "Connect a writable Google calendar before adding an event."; return
        }
        let key = ThreadKey(accountID: link.accountID, threadID: link.threadID)
        let revision = lifecycleRevision
        editRevision += 1
        let edit = editRevision
        var draft = CalendarEditorDraft(event: range.applying(to: GoogleCalendarEvent(summary: ""), calendar: calendar), calendarKey: owner.id)
        draft.sourceTitle = "From a conversation. Check the title and time before saving."
        statusText = "Reading the conversation…"
        do {
            if let detail = try await droppedThreadDetail(key) {
                let suggestions = EmailCalendarModel()
                await loadEmailSuggestions(suggestions, detail: detail, key: key)
                if let service = try? app?.assistant.calendarExtractionService(for: key) {
                    await interpretEmailSuggestions(suggestions, key: key, service: service)
                }
                try validateEmailLifetime(revision, accountID: link.accountID)
                guard edit == editRevision else { return }
                let items = suggestions.visibleItems.filter(\.canReview)
                let item = items.first { $0.messageID == link.messageID && $0.event != nil }
                    ?? items.first { $0.event != nil } ?? items.first
                var event = item?.event ?? GoogleCalendarEvent(summary: "")
                // The drop decides when; a personal copy never invites the sender's guests.
                event.summary = item.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? detail.thread.subject
                event.attendees = nil
                event.organizer = nil
                draft.event = range.applying(to: event, calendar: calendar)
                if let item { draft.sourceID = key.accountID + ":" + item.id }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "The conversation could not be read. Fill in the event by hand."
        }
        guard edit == editRevision else { return }
        statusText = "Review the event, then save it."
        editor = draft
    }

    /// The thread as the mailbox has it, with bodies loaded so dates can be read.
    private func droppedThreadDetail(_ key: ThreadKey) async throws -> ThreadDetail? {
        guard let mailbox = app?.mailbox else { return nil }
        _ = await mailbox.open(key, markRead: false)
        for try await detail in mailbox.threadDetail(key) { return detail }
        return nil
    }
}
