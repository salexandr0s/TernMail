import Foundation
import GmailAPI
import MailStore
import MessageContent
import SyncEngine

extension CalendarModel {
    func prepareEmailResponse(_ item: EmailCalendarItem, answer: InvitationReply.Answer, key: ThreadKey) async throws -> EmailCalendarResponseReview {
        let revision = lifecycleRevision
        guard !item.isOutdated, let invitation = item.invitation, !invitation.isCancelled,
              let owner = app?.mailbox?.account(id: key.accountID) else { throw CalendarInvitationError.missing }
        try await owner.engine.validateCalendarInvitation(messageID: item.messageID, uid: invitation.uid, recurrenceKey: invitation.recurrenceKey)
        try validateEmailLifetime(revision, accountID: key.accountID)
        if let previous = try await owner.engine.calendarInvitationReply(uid: invitation.uid, recurrenceKey: invitation.recurrenceKey) {
            try validateEmailLifetime(revision, accountID: key.accountID)
            if previous.participationStatus.rawValue == answer.rawValue {
                throw CalendarModelError.unsupported("This response was already queued by email. Check the Outbox for its status.")
            }
            // An existing fallback fixes the delivery route; changing it must not also RSVP through Google.
            return EmailCalendarResponseReview(item: item, answer: answer, delivery: .email,
                explanation: "Send an email response to \(invitation.organizer?.email ?? "the organizer")? This does not add an event.")
        }
        if let match = try await emailInvitationMatch(invitation, accountID: key.accountID), match.event.attendees?.contains(where: { $0.isSelf == true }) == true {
            try validateEmailLifetime(revision, accountID: key.accountID)
            return EmailCalendarResponseReview(item: item, answer: answer,
                delivery: .google(calendarID: match.calendarID, eventID: match.event.id),
                explanation: "Google Calendar will deliver your response to \(match.event.organizer?.email ?? invitation.organizer?.email ?? "the organizer"). Guests may receive a meeting update.")
        }
        try validateEmailLifetime(revision, accountID: key.accountID)
        if let links = try await store?.sourceLinks(accountID: key.accountID), links.contains(where: {
            $0.id.hasPrefix("rsvp:") && $0.invitationUID == invitation.uid && $0.recurrenceKey == invitation.recurrenceKey
        }) { throw CalendarModelError.unsupported("This invitation uses Google Calendar for responses. Check its Calendar activity before replying again.") }
        // An uncertain earlier Google response keeps its delivery route even if the invitation disappears.
        if let previous = try await store?.operations(accountID: key.accountID), previous.contains(where: {
            guard case .respond = $0.mutation else { return false }
            return $0.resultEvent?.iCalUID == invitation.uid || ($0.calendarID == item.existingCalendarID && $0.mutation.eventID == item.existingEventID)
        }) { throw CalendarModelError.unsupported("This invitation already has a Google Calendar response. Review it in Calendar activity before replying again.") }
        try validateEmailLifetime(revision, accountID: key.accountID)
        return EmailCalendarResponseReview(item: item, answer: answer, delivery: .email,
            explanation: "Send an email response to \(invitation.organizer?.email ?? "the organizer")? This does not add an event.")
    }

    func sendEmailResponse(_ review: EmailCalendarResponseReview, key: ThreadKey) async throws {
        let revision = lifecycleRevision
        guard let invitation = review.item.invitation, let owner = app?.mailbox?.account(id: key.accountID) else { throw CalendarInvitationError.missing }
        let responseKey = key.accountID + ":" + invitation.uid + ":" + invitation.recurrenceKey
        guard emailResponsesInFlight.insert(responseKey).inserted else { throw CalendarInvitationError.responsePending }
        defer { emailResponsesInFlight.remove(responseKey) }
        let latest = try await prepareEmailResponse(review.item, answer: review.answer, key: key)
        try validateEmailLifetime(revision, accountID: key.accountID)
        switch (review.delivery, latest.delivery) {
        case let (.google(calendarID, eventID), .google(currentCalendar, currentEvent)) where calendarID == currentCalendar && eventID == currentEvent:
            guard let engine = engines[key.accountID] else { throw CalendarModelError.unavailable }
            let event = try await engine.readEvent(calendarID: calendarID, eventID: eventID, refresh: true)
            try validateEmailLifetime(revision, accountID: key.accountID)
            let status = review.answer.rawValue.lowercased()
            if event.attendees?.first(where: { $0.isSelf == true })?.responseStatus == status { return }
            let previous = try await store?.operations(accountID: key.accountID) ?? []
            try validateEmailLifetime(revision, accountID: key.accountID)
            if let pending = previous.last(where: {
                if case .respond(let id, _, _) = $0.mutation { return id == eventID && $0.calendarID == calendarID && [.queued, .running].contains($0.status) }
                return false
            }) {
                if case .respond(_, let old, _) = pending.mutation, old == status { return }
                throw CalendarInvitationError.responsePending
            }
            try validateEmailLifetime(revision, accountID: key.accountID)
            try await store?.saveSourceLink(CalendarSourceLink(id: "rsvp:" + responseKey, accountID: key.accountID,
                calendarID: calendarID, eventID: eventID, threadID: key.threadID, messageID: review.item.messageID,
                invitationUID: invitation.uid, recurrenceKey: invitation.recurrenceKey))
            try validateEmailLifetime(revision, accountID: key.accountID)
            _ = try await engine.enqueue(.respond(eventID: eventID, status: status, etag: event.etag), calendarID: calendarID)
            // Once durable, a temporary network failure leaves one queued response for retry.
            do { try await engine.flush() }
            catch { statusText = "Your invitation response is queued and waiting to sync." }
            await reloadOperations()
        case (.email, .email):
            _ = try await owner.engine.replyToCalendarInvitation(messageID: review.item.messageID, uid: invitation.uid,
                recurrenceKey: invitation.recurrenceKey, answer: review.answer, delay: 10)
        default: throw CalendarModelError.unsupported("The invitation changed. Review the response destination again.")
        }
    }

    func emailInvitationMatch(_ invitation: Invitation, accountID: String) async throws -> (calendarID: String, event: GoogleCalendarEvent)? {
        let revision = lifecycleRevision
        if app?.mailbox?.account(id: accountID)?.account.enabledFeatures.contains(AccountFeature.calendar.rawValue) == true,
           !calendars.contains(where: { $0.accountID == accountID && $0.entry.canReadDetails && $0.entry.primary == true }) {
            throw CalendarModelError.unsupported("Your primary Google calendar could not be checked. Connect or refresh Calendar before continuing.")
        }
        let original = invitation.recurrenceKey.isEmpty ? nil : try CalendarInterchange.googleException(from: invitation,
            parentEventID: "lookup", fallbackTimeZone: calendar.timeZone).originalStartTime
        for owner in calendars.filter({ $0.accountID == accountID && $0.entry.canReadDetails }).sorted(by: { $0.entry.primary == true && $1.entry.primary != true }) {
            guard let engine = engines[accountID] else { throw CalendarModelError.unavailable }
            if let event = try await engine.matchInvitation(calendarID: owner.calendarID, iCalUID: invitation.uid, originalStart: original).first {
                try validateEmailLifetime(revision, accountID: accountID)
                return (owner.calendarID, event)
            }
        }
        try validateEmailLifetime(revision, accountID: accountID)
        return nil
    }

    static func isNewer(_ invitation: Invitation, than event: GoogleCalendarEvent) -> Bool {
        if invitation.sequence != (event.sequence ?? 0) { return invitation.sequence > (event.sequence ?? 0) }
        guard let stamp = invitation.stamp, let updated = event.updated.flatMap(CalendarDateCoding.date) else { return false }
        return stamp > updated
    }

    func validateEmailLifetime(_ revision: Int, accountID: String) throws {
        try Task.checkCancellation()
        guard revision == lifecycleRevision, app?.mailbox?.account(id: accountID) != nil else { throw CalendarModelError.unavailable }
    }

}
