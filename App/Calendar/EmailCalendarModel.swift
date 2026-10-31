import CryptoKit
import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation

struct EmailCalendarMessage: Sendable, Equatable {
    let id: String
    let subject: String
    let date: Date
    let text: String
    var invitations: [Invitation] = []
    var sender = ""
    /// Gmail's Promotions and Social mail is full of sale periods, opening hours
    /// and notification times, so its dates are not read as events locally.
    var allowsDateDetection = true
    /// Seconds east of UTC in the message's `Date` header. Nil when the header
    /// names no zone, and for messages cached before the offset was stored.
    var dateHeaderOffset: Int?
}

extension EmailCalendarMessage {
    /// A time without a zone is worth checking only when the sender's clock
    /// read differently from the reader's. Nil when nothing suggests that.
    func timeZoneWarning(readerTimeZone: TimeZone) -> String? {
        guard let difference = CalendarDetection.senderClockDifference(
            dateHeaderOffset: dateHeaderOffset, sentAt: date, readerTimeZone: readerTimeZone) else { return nil }
        // The sentence is English, so the amount is too.
        let amount = Duration.seconds(abs(difference))
            .formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(Locale(identifier: "en")))
        return "Check the time zone. The sender's clock is \(amount) \(difference < 0 ? "behind" : "ahead of") yours."
    }
}

struct EmailCalendarItem: Identifiable, Sendable, Equatable, Codable {
    enum Kind: String, Codable, Sendable { case detected, proposed, updated, cancelled, invitation, response }
    let id: String
    let messageID: String
    var title: String
    var evidence: String
    var kind: Kind
    var event: GoogleCalendarEvent?
    var invitation: Invitation?
    var uncertainties: [String] = []
    var isOutdated = false
    var existingCalendarID: String?
    var existingEventID: String?
    var relatedMessageIDs: [String] = []
    var hasAmbiguousMatch = false
    var previousAnswer: Invitation.ParticipationStatus?
    var calendarAnswer: Invitation.ParticipationStatus?
    var authenticityWarning: String?

    var canReview: Bool { kind != .response && !isOutdated && !hasAmbiguousMatch && (kind != .cancelled || existingEventID != nil) }
}

@MainActor @Observable
final class EmailCalendarModel {
    private(set) var items: [EmailCalendarItem] = []
    private(set) var messages: [EmailCalendarMessage] = []
    private(set) var revision = ""
    private(set) var isInterpreting = false
    private(set) var interpretationError: String?
    private(set) var addresses: [String] = []
    private var dismissedIDs = Set<String>()
    private var interpretedRevision: String?
    private var timeZone: TimeZone = .autoupdatingCurrent
    private var generation = 0
    private var interpretedItems: [EmailCalendarItem]?
    private var invitationState = CalendarInvitationState()
    private var referenceDate = Date.now

    var cachedInterpretation: [EmailCalendarItem]? { interpretedRevision == revision ? interpretedItems : nil }

    var visibleItems: [EmailCalendarItem] { items.filter { !dismissedIDs.contains($0.id) } }

    func update(messages: [EmailCalendarMessage], addresses: [String],
                timeZone: TimeZone = .autoupdatingCurrent, dismissedIDs: Set<String> = [],
                invitationState: CalendarInvitationState = .init(), now: Date = .now) {
        let addressesChanged = self.addresses != addresses
        self.addresses = addresses
        self.invitationState = invitationState
        self.dismissedIDs.formUnion(dismissedIDs)
        let fingerprint = Self.fingerprint(messages, timeZone: timeZone)
        let revisionChanged = fingerprint != revision
        guard revisionChanged || addressesChanged else {
            refreshInvitationState()
            return
        }
        // Reply addresses only decide which attendee replies show, so a reading
        // of the same messages, finished or still running, stays in place.
        if revisionChanged {
            generation += 1
            revision = fingerprint
            interpretationError = nil
            isInterpreting = false
            interpretedItems = nil
        }
        self.messages = messages
        self.timeZone = timeZone
        referenceDate = now
        var next: [EmailCalendarItem] = []
        for message in messages {
            let invitations = message.invitations.flatMap { [$0] + ($0.additionalEvents ?? []) }
            for invitation in invitations {
                let isResponse = invitation.method == .reply
                if invitation.isAttendeeMessage {
                    guard isResponse, addresses.contains(where: { invitation.organizer?.matches($0) == true }) else { continue }
                }
                let key = invitation.uid + ":" + invitation.recurrenceKey
                var errors: [String] = []
                let displayInvitation = isResponse ? invitationState.invitations.map(\.invitation).filter {
                    $0.uid == invitation.uid && $0.recurrenceKey == invitation.recurrenceKey && !$0.isAttendeeMessage
                }.max { ($0.sequence, $0.stamp ?? .distantPast) < ($1.sequence, $1.stamp ?? .distantPast) } : invitation
                if case .floating = displayInvitation?.start { errors.append("Check the time zone.") }
                let converted: GoogleCalendarEvent?
                do {
                    converted = try displayInvitation.map {
                        $0.recurrenceKey.isEmpty
                            ? try CalendarInterchange.googleEvent(from: $0, fallbackTimeZone: timeZone)
                            : try CalendarInterchange.googleException(from: $0, parentEventID: "email-preview", fallbackTimeZone: timeZone)
                    }
                }
                catch { converted = nil; errors.append(error.localizedDescription) }
                next.append(EmailCalendarItem(
                    id: "invitation:" + message.id + ":" + key,
                    messageID: message.id, title: invitation.summary ?? displayInvitation?.summary ?? "Calendar invitation",
                    evidence: invitation.location ?? "", kind: isResponse ? .response : invitation.isCancelled ? .cancelled : .invitation,
                    event: converted, invitation: invitation, uncertainties: errors
                ))
            }
            // Structured data supplies the precise event; text detection must not
            // create another candidate for the invitation's readable alternative.
            guard invitations.isEmpty, message.allowsDateDetection else { continue }
            let zoneWarning = message.timeZoneWarning(readerTimeZone: timeZone)
            for suggestion in CalendarDetection.suggestions(in: message.text, messageDate: message.date, timeZone: timeZone) {
                var event = GoogleCalendarEvent(summary: message.subject)
                event.start = CalendarDateTime(date: suggestion.start, timeZone: timeZone, allDay: suggestion.isAllDay)
                if let end = suggestion.end {
                    event.end = CalendarDateTime(date: end, timeZone: timeZone, allDay: suggestion.isAllDay)
                }
                let warnings = suggestion.uncertainties.compactMap { uncertainty -> String? in
                    switch uncertainty {
                    case .dateNeedsReview: "Check the intended date."
                    case .timeNeedsReview: "Check the intended time."
                    case .timeZoneMissing: zoneWarning
                    case .durationMissing: "Choose an event duration."
                    }
                }
                next.append(EmailCalendarItem(
                    id: "detected:" + message.id + ":" + suggestion.id,
                    messageID: message.id, title: message.subject.isEmpty ? "Event from email" : message.subject,
                    evidence: suggestion.sourceText, kind: .detected, event: event,
                    invitation: nil, uncertainties: warnings
                ))
            }
        }
        items = next.filter(isCurrent)
        if let interpretation = cachedInterpretation { mergeInterpretation(interpretation) }
        refreshInvitationState()
    }

    /// A suggestion without a date, or one that has already ended, leaves nothing
    /// to add to a calendar. Invitations, updates and cancellations still show.
    private func isCurrent(_ item: EmailCalendarItem) -> Bool {
        guard item.kind == .detected || item.kind == .proposed else { return true }
        guard let event = item.event, let start = event.start?.resolvedDate(fallbackTimeZone: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let end = event.end?.resolvedDate(fallbackTimeZone: timeZone)
            ?? (event.isAllDay ? calendar.date(byAdding: .day, value: 1, to: start) : start)
        return (end ?? start) > referenceDate
    }

    private func refreshInvitationState() {
        let versions = invitationState.invitations.map(\.invitation) + messages.flatMap {
            $0.invitations.flatMap { [$0] + ($0.additionalEvents ?? []) }
        }
        for index in items.indices {
            guard let invitation = items[index].invitation else { continue }
            items[index].isOutdated = !invitation.isAttendeeMessage && versions.contains { other in
                other.uid == invitation.uid && !other.isAttendeeMessage &&
                (other.recurrenceKey == invitation.recurrenceKey || (other.recurrenceKey.isEmpty && other.isCancelled)) &&
                (other.sequence, other.stamp ?? .distantPast) > (invitation.sequence, invitation.stamp ?? .distantPast)
            }
            items[index].previousAnswer = invitationState.replies.first {
                $0.uid == invitation.uid && $0.recurrenceKey == invitation.recurrenceKey
            }?.participationStatus
            if invitation.method == .reply { continue }
            let sender = messages.first { $0.id == items[index].messageID }.flatMap { EmailAddress.parseList($0.sender).first?.address }
            if let organizer = invitation.organizer?.email, let sender, sender.caseInsensitiveCompare(organizer) != .orderedSame {
                items[index].authenticityWarning = "The email sender differs from the event organizer. Replies go to \(organizer)."
            } else { items[index].authenticityWarning = nil }
        }
    }

    func interpret(using service: EmailCalendarExtractionService) async {
        guard !isInterpreting, interpretedRevision != revision, !messages.isEmpty else { return }
        let currentGeneration = generation
        let currentRevision = revision
        isInterpreting = true
        interpretationError = nil
        do {
            let interpreted = try await service.extract(messages: messages, timeZone: timeZone)
            guard generation == currentGeneration, !Task.isCancelled else { return }
            _ = restoreInterpretation(interpreted, for: currentRevision)
        } catch is CancellationError {
        } catch {
            guard generation == currentGeneration else { return }
            interpretationError = error.localizedDescription
        }
        if generation == currentGeneration { isInterpreting = false }
    }

    @discardableResult
    func restoreInterpretation(_ interpreted: [EmailCalendarItem], for sourceRevision: String) -> Bool {
        guard revision == sourceRevision, interpreted.count <= 20, Set(interpreted.map(\.id)).count == interpreted.count,
              interpreted.allSatisfy({ item in
                  item.id.hasPrefix("interpreted:") && item.invitation == nil && !item.evidence.isEmpty &&
                  [.proposed, .updated, .cancelled].contains(item.kind) &&
                  messages.contains { $0.id == item.messageID && CalendarDetection.unquotedText($0.text).contains(item.evidence) } &&
                  item.relatedMessageIDs.allSatisfy { id in messages.contains { $0.id == id } }
              }) else { return false }
        mergeInterpretation(interpreted)
        interpretedRevision = sourceRevision
        interpretedItems = interpreted
        return true
    }

    private func mergeInterpretation(_ interpreted: [EmailCalendarItem]) {
        let structuredMessageIDs = Set(items.filter { $0.invitation != nil }.map(\.messageID))
        let useful = interpreted.filter { !structuredMessageIDs.contains($0.messageID) && isCurrent($0) }
        // The interpretation reads the whole conversation, so it replaces every
        // text detection, including the dates it found not to be events.
        items.removeAll { $0.invitation == nil }
        items.append(contentsOf: useful)
    }

    func markAmbiguous(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].hasAmbiguousMatch = true
        let message = "Several saved events match this correction. Open Calendar to choose the intended event."
        if !items[index].uncertainties.contains(message) { items[index].uncertainties.append(message) }
    }

    func markExisting(itemID: String, calendarID: String, eventID: String, hasNewerInvitation: Bool = false,
                      calendarAnswer: Invitation.ParticipationStatus? = nil) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].existingCalendarID = calendarID
        items[index].existingEventID = eventID
        items[index].calendarAnswer = calendarAnswer
        if hasNewerInvitation, items[index].kind != .cancelled, items[index].kind != .response { items[index].kind = .updated }
    }

    func restoreCorrection(itemID: String, event: GoogleCalendarEvent) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].event = event
        items[index].title = event.summary ?? items[index].title
    }

    func dismiss(_ id: String) { dismissedIDs.insert(id) }

    func clearAIResults() {
        let sourceMessages = messages
        revision = ""
        interpretedRevision = nil
        update(messages: sourceMessages, addresses: addresses, timeZone: timeZone, invitationState: invitationState)
    }

    func attendee(for item: EmailCalendarItem) -> Invitation.Participant? {
        item.invitation?.attendee(matchingAnyOf: addresses)
    }

    /// Part of every revision. Raise it when the same mail should give different
    /// cards, so readings the assistant cached under the old rules are not reused.
    private static let rulesVersion = 1

    private static func fingerprint(_ messages: [EmailCalendarMessage], timeZone: TimeZone) -> String {
        var hash = SHA256()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        hash.update(data: Data("rules-\(rulesVersion)".utf8))
        hash.update(data: Data(timeZone.identifier.utf8))
        for message in messages {
            let offset = message.dateHeaderOffset.map { String($0) } ?? ""
            for part in [message.id, message.subject, String(message.date.timeIntervalSince1970), message.text, message.sender, offset] {
                hash.update(data: Data("\(part.utf8.count):".utf8))
                hash.update(data: Data(part.utf8))
            }
            if let data = try? encoder.encode(message.invitations) { hash.update(data: data) }
            // Only a change from the default alters the revision, so readings
            // cached for ordinary mail stay valid.
            if !message.allowsDateDetection { hash.update(data: Data("without-date-detection".utf8)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
