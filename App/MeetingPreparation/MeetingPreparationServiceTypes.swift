import Foundation
import GmailAPI
import MailStore
import MessageContent

/// Includes the monotonic consent revision, not chat navigation or chat history.
struct MeetingPreparationAccess: Equatable, Sendable {
    let scope: AssistantScopeSnapshot
    let modelID: String
    let modelReady: Bool
    let permissionRevision: Int
    let mailboxRuntime: String
    var calendarLifecycle = 0
}

struct MeetingPreparationCandidate: Identifiable, Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case included, eventLink, titleMatch
        var title: String {
            switch self {
            case .included: "Included by you"
            case .eventLink: "Linked to event"
            case .titleMatch: "Matches event title"
            }
        }
        var explanation: String {
            switch self {
            case .included: "Included by you."
            case .eventLink: "Linked to this event in Tern."
            case .titleMatch: "The subject or message content matches distinctive words in this event's title."
            }
        }
    }
    let thread: ThreadKey
    let title: String
    let reason: Reason
    let source: MailLink
    var id: String { "\(thread.accountID.utf8.count):\(thread.accountID)\(thread.threadID)" }
}

struct MeetingPreparationDiscovery: Equatable, Sendable {
    let candidates: [MeetingPreparationCandidate]
    let omittedCount: Int
    let hasMoreSearchResults: Bool
    let requiresManualSelection: Bool
    let failures: [String]
}

struct MeetingPreparationAttachment: Identifiable, Equatable, Sendable {
    let source: AssistantSource
    let filename: String
    let sender: String
    let date: Date
    let size: Int
    let mimeType: String
    var id: String { source.id }
}

struct MeetingPreparationThreadReport: Identifiable, Equatable, Sendable {
    let candidate: MeetingPreparationCandidate
    let report: ThreadSummaryReport
    let detail: ThreadDetail
    let revision: String
    let attachments: [MeetingPreparationAttachment]
    var id: String { candidate.id }
}

struct MeetingPreparationSourceSnapshot: Sendable {
    let detail: ThreadDetail
    /// The raw cache snapshot's revision, before restricting its membership to
    /// the authoritative metadata response. Used only for staleness checks.
    let revision: String
}

enum MeetingPreparationServiceError: Error, LocalizedError, Equatable {
    case calendarDetailsRequired, noMailAccess, sourceUnavailable, reportLimit, invalidSource, eventChanged
    var errorDescription: String? {
        switch self {
        case .calendarDetailsRequired: "Allow assistant access to event details for this calendar to prepare the meeting."
        case .noMailAccess: "Enable assistant access for a mail account to find related conversations."
        case .sourceUnavailable: "This conversation is unavailable. You can keep its source link and try again."
        case .reportLimit: "This preparation can summarize five conversations. Narrow the included sources and refresh to summarize others."
        case .invalidSource: "The returned source does not match this conversation. Refresh to try again."
        case .eventChanged: "This event changed. Refresh its preparation to continue."
        }
    }
}

enum MeetingPreparationMatching {
    static func terms(in event: CalendarDisplayEvent) -> [String] {
        let people = (event.event.attendees ?? []).flatMap { [$0.email, $0.displayName ?? ""] }
            + [event.event.organizer?.email ?? "", event.event.organizer?.displayName ?? ""]
        let personWords = Set(people.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted))
        let words = terms(in: event.title).filter { !personWords.contains($0) }
        return words.count >= 2 || words.first.map({ $0.count >= 6 }) == true ? words : []
    }

    /// Generic titles deliberately produce no person-based fallback. Search
    /// query terms contain letters/numbers only, so titles cannot add operators.
    static func terms(in title: String) -> [String] {
        let generic: Set<String> = ["meeting", "meet", "catch", "catchup", "sync", "standup", "weekly", "monthly", "daily",
            "quarterly", "review", "status", "call", "planning", "discussion", "team", "agenda", "check", "follow", "update",
            "project", "budget", "prep", "preparation", "report", "presentation", "kickoff", "introduction", "session",
            "design", "with", "from", "about", "this", "that", "your", "their", "the", "and", "for"]
        var seen = Set<String>()
        let words = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && $0.unicodeScalars.contains(where: CharacterSet.letters.contains)
                && !generic.contains($0) && seen.insert($0).inserted }
        guard words.count >= 2 || words.first.map({ $0.count >= 6 }) == true else { return [] }
        return Array(words.prefix(4))
    }

    static func matches(subject: String, snippet: String, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let words = Set((subject + " " + snippet)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted))
        // Matching two distinctive words is evidence even when a long event
        // title contains additional context that is absent from an email.
        return terms.filter(words.contains).count >= min(2, terms.count)
    }
}
