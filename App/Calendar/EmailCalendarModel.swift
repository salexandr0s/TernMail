import CryptoKit
import Foundation
import GmailAPI
import MessageContent
import Observation

struct EmailCalendarMessage: Sendable, Equatable {
    let id: String
    let subject: String
    let date: Date
    let text: String
    var invitations: [Invitation] = []
}

struct EmailCalendarItem: Identifiable, Sendable, Equatable, Codable {
    enum Kind: String, Codable, Sendable { case detected, proposed, updated, cancelled, invitation }
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

    var canReview: Bool { !isOutdated && !hasAmbiguousMatch && (kind != .cancelled || existingEventID != nil) }
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

    var cachedInterpretation: [EmailCalendarItem]? { interpretedRevision == revision ? interpretedItems : nil }

    var visibleItems: [EmailCalendarItem] { items.filter { !dismissedIDs.contains($0.id) } }

    func update(messages: [EmailCalendarMessage], addresses: [String],
                timeZone: TimeZone = .autoupdatingCurrent, dismissedIDs: Set<String> = []) {
        self.addresses = addresses
        self.dismissedIDs.formUnion(dismissedIDs)
        let fingerprint = Self.fingerprint(messages, timeZone: timeZone)
        guard fingerprint != revision else { return }
        generation += 1
        self.messages = messages
        self.timeZone = timeZone
        revision = fingerprint
        interpretationError = nil
        isInterpreting = false
        interpretedItems = nil
        var next: [EmailCalendarItem] = []
        for message in messages {
            let invitations = message.invitations.flatMap { [$0] + ($0.additionalEvents ?? []) }
            for invitation in invitations where !invitation.isAttendeeMessage {
                let key = invitation.uid + ":" + invitation.recurrenceKey
                var errors: [String] = []
                if case .floating = invitation.start { errors.append("Check the time zone.") }
                let converted: GoogleCalendarEvent?
                do { converted = try CalendarInterchange.googleEvent(from: invitation, fallbackTimeZone: timeZone) }
                catch { converted = nil; errors.append(error.localizedDescription) }
                next.append(EmailCalendarItem(
                    id: "invitation:" + message.id + ":" + key,
                    messageID: message.id, title: invitation.summary ?? "Calendar invitation",
                    evidence: invitation.location ?? "", kind: invitation.isCancelled ? .cancelled : .invitation,
                    event: converted, invitation: invitation, uncertainties: errors
                ))
            }
            // Structured data supplies the precise event; text detection must not
            // create another candidate for the invitation's readable alternative.
            guard invitations.isEmpty else { continue }
            for suggestion in CalendarDetection.suggestions(in: message.text, messageDate: message.date, timeZone: timeZone) {
                var event = GoogleCalendarEvent(summary: message.subject)
                if let start = suggestion.start {
                    event.start = CalendarDateTime(date: start, timeZone: timeZone, allDay: suggestion.isAllDay)
                }
                if let end = suggestion.end {
                    event.end = CalendarDateTime(date: end, timeZone: timeZone, allDay: suggestion.isAllDay)
                }
                let warnings = suggestion.uncertainties.map { uncertainty in
                    switch uncertainty {
                    case .dateNeedsReview: "Choose the intended date."
                    case .timeNeedsReview: "Check the intended time."
                    case .timeZoneMissing: "Check the time zone."
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
        for index in next.indices {
            guard let invitation = next[index].invitation else { continue }
            next[index].isOutdated = next.contains { candidate in
                guard let other = candidate.invitation, other.uid == invitation.uid,
                      other.recurrenceKey == invitation.recurrenceKey || (other.recurrenceKey.isEmpty && other.isCancelled) else { return false }
                return (other.sequence, other.stamp ?? .distantPast) > (invitation.sequence, invitation.stamp ?? .distantPast)
            }
        }
        items = next
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
        let structuredMessageIDs = Set(items.filter { $0.invitation != nil }.map(\.messageID))
        let useful = interpreted.filter { !structuredMessageIDs.contains($0.messageID) }
        let interpretedMessageIDs = Set(useful.flatMap { [$0.messageID] + $0.relatedMessageIDs })
        items.removeAll { $0.invitation == nil && interpretedMessageIDs.contains($0.messageID) }
        items.append(contentsOf: useful)
        interpretedRevision = sourceRevision
        interpretedItems = interpreted
        return true
    }

    func markAmbiguous(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].hasAmbiguousMatch = true
        let message = "Several saved events match this correction. Open Calendar to choose the intended event."
        if !items[index].uncertainties.contains(message) { items[index].uncertainties.append(message) }
    }

    func markExisting(itemID: String, calendarID: String, eventID: String, hasNewerInvitation: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].existingCalendarID = calendarID
        items[index].existingEventID = eventID
        if hasNewerInvitation, items[index].kind != .cancelled { items[index].kind = .updated }
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
        update(messages: sourceMessages, addresses: addresses, timeZone: timeZone)
    }

    func attendee(for item: EmailCalendarItem) -> Invitation.Participant? {
        item.invitation?.attendee(matchingAnyOf: addresses)
    }

    private static func fingerprint(_ messages: [EmailCalendarMessage], timeZone: TimeZone) -> String {
        var hash = SHA256()
        hash.update(data: Data(timeZone.identifier.utf8))
        for message in messages {
            for part in [message.id, message.subject, String(message.date.timeIntervalSince1970), message.text] {
                hash.update(data: Data("\(part.utf8.count):".utf8))
                hash.update(data: Data(part.utf8))
            }
            if let data = try? JSONEncoder().encode(message.invitations) { hash.update(data: data) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
