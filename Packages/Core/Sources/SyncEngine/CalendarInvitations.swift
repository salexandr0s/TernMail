import Foundation
import GmailAPI
import MailStore
import MessageContent

public enum CalendarInvitationError: Error, Sendable, LocalizedError {
    case missing, outdated, notAttendee, responsePending
    public var errorDescription: String? {
        switch self {
        case .missing: "This invitation is no longer available. Open the conversation again."
        case .outdated: "A newer invitation or cancellation is available. Review it before replying."
        case .notAttendee: "This account is not an attendee of this invitation."
        case .responsePending: "A response is already queued. Undo it before choosing a different answer."
        }
    }
}

extension SyncEngine {
    public func calendarInvitations(threadID: String) async throws -> [MessageCalendarRecord] {
        let accountID = accountID
        return try await cache.read { try $0.calendarInvitations(accountID: accountID, threadID: threadID) }
    }

    public func calendarReplyAddresses() async throws -> [String] {
        let aliases = try await accounts?.identities(accountID: accountID) ?? []
        return [sender.address] + aliases.filter(\.canSend).map(\.address)
    }

    public func calendarInvitationReply(uid: String, recurrenceKey: String) async throws -> InvitationReplyRecord? {
        let accountID = accountID
        return try await cache.read { try $0.invitationReply(uid: uid, recurrenceKey: recurrenceKey, accountID: accountID) }
    }

    public func validateCalendarInvitation(messageID: String, uid: String, recurrenceKey: String) async throws {
        let accountID = accountID
        try await cache.read { tx in
            let records = try tx.calendarInvitations(accountID: accountID)
            guard let source = records.first(where: { $0.messageID == messageID && $0.uid == uid && $0.recurrenceKey == recurrenceKey }),
                  source.invitation.method == .request, !source.invitation.isCancelled else { throw CalendarInvitationError.missing }
            guard !records.contains(where: {
                $0.uid == uid && ($0.recurrenceKey == recurrenceKey || ($0.recurrenceKey.isEmpty && $0.invitation.isCancelled))
                    && !$0.invitation.isAttendeeMessage && source.isOlder(than: $0)
            }) else { throw CalendarInvitationError.outdated }
        }
    }

    /// Reads the invitation and inline pictures of bodies cached before that
    /// was done, from one full fetch of the conversation. Once every body is
    /// marked enriched in the cache, this costs no request, across launches.
    public func refreshCalendarInvitations(threadID: String) async throws {
        try await loadReadingThread(threadID, enrichCached: true, foreground: true)
    }

    /// This is the fallback for an invitation absent from Google Calendar. The caller first
    /// checks Google, then asks the user to send exactly this email reply. A private copy never calls it.
    /// The answer, immutable draft and send action commit atomically; repeated clicks reuse the receipt.
    public func replyToCalendarInvitation(messageID: String, uid: String, recurrenceKey: String,
                                           answer: InvitationReply.Answer, delay: TimeInterval) async throws -> InvitationReplyRecord {
        let accountID = accountID
        let addresses = try await calendarReplyAddresses()
        let timestamp = now()
        let rendering = await provisionalRendering(at: timestamp)
        let receipt = try await write { tx in
            guard let message = try tx.message(id: messageID, accountID: accountID),
                  let source = try tx.calendarInvitations(accountID: accountID).first(where: {
                      $0.messageID == messageID && $0.uid == uid && $0.recurrenceKey == recurrenceKey
                  }), source.invitation.method == .request, !source.invitation.isCancelled else { throw CalendarInvitationError.missing }
            let records = try tx.calendarInvitations(accountID: accountID)
            guard !records.contains(where: {
                $0.uid == uid && ($0.recurrenceKey == recurrenceKey || ($0.recurrenceKey.isEmpty && $0.invitation.isCancelled))
                && !$0.invitation.isAttendeeMessage && source.isOlder(than: $0)
            }) else { throw CalendarInvitationError.outdated }
            guard let attendee = source.invitation.attendee(matchingAnyOf: addresses), let email = attendee.email,
                  let organizer = source.invitation.organizer?.email, EmailAddress(address: organizer).isValid else {
                throw CalendarInvitationError.notAttendee
            }
            let status = Invitation.ParticipationStatus(rawValue: answer.rawValue) ?? .needsAction
            if let old = try tx.invitationReply(uid: uid, recurrenceKey: recurrenceKey, accountID: accountID) {
                if old.participationStatus == status { return old }
                if try tx.localDraft(id: old.localDraftID) != nil { throw CalendarInvitationError.responsePending }
            }
            let subject = InvitationReply.subject(for: answer, summary: source.invitation.summary)
            let draft = LocalDraft(accountID: accountID, kind: .invitationReply,
                content: DraftContent(to: [EmailAddress(address: organizer)], subject: subject,
                    body: ComposeDocument(plainText: subject), fromAddress: email),
                rfcMessageID: "<\(UUID().uuidString.lowercased())@tern.local>", threadID: message.threadID,
                sourceMessageID: messageID, inReplyTo: message.rfcMessageID,
                references: [message.rfcMessageID].compactMap { $0 },
                calendarPart: InvitationReply.calendar(replyingTo: source.invitation, as: attendee, answer: answer, now: timestamp), now: timestamp)
            try tx.insertLocalDraft(draft)
            let receipt = InvitationReplyRecord(accountID: accountID, uid: uid, recurrenceKey: recurrenceKey,
                participationStatus: status, localDraftID: draft.id, queuedAt: timestamp)
            try tx.saveInvitationReply(receipt)
            guard try tx.enqueueSend(
                localDraftID: draft.id, now: timestamp, notBefore: timestamp.addingTimeInterval(max(0, delay)), rendering: rendering
            ) != nil else {
                throw CalendarInvitationError.responsePending
            }
            return receipt
        }
        scheduleSending()
        return receipt
    }
}
