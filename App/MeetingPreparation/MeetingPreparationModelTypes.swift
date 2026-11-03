import Foundation
import MailStore
import MessageContent
import TernAI

enum MeetingPreparationState: Equatable {
    case idle, loading, ready, cancelled, permissionDisabled, providerUnavailable, unavailable
}

struct MeetingPreparationSourceRow: Identifiable, Equatable {
    let key: ThreadKey
    let link: MailLink
    let title: String
    let reason: String
    let isExcluded: Bool
    let isExplicitlyIncluded: Bool
    let unavailableMessage: String?
    var id: String { "\(key.accountID.utf8.count):\(key.accountID)\(key.threadID)" }
}

struct MeetingPreparationTaskSuggestion: Identifiable {
    let task: AssistantSummary.OpenTask
    let sources: [AssistantSource]
    let request: FollowUpSuggestionRequest
    var id: String { "\(request.source.accountID.utf8.count):\(request.source.accountID)\(request.acceptanceKey)" }
}

struct MeetingPreparationSection: Identifiable {
    let candidate: MeetingPreparationCandidate
    let report: ThreadSummaryReport
    let suggestions: [MeetingPreparationTaskSuggestion]
    let trackedWork: [CommitmentEntry]
    let suppressedSuggestionCount: Int
    var id: String { "\(candidate.thread.accountID.utf8.count):\(candidate.thread.accountID)\(candidate.thread.threadID)" }
}

struct MeetingPreparationGeneration {
    let isCurrent: @MainActor () -> Bool
}

/// The model can test suspended operations without opening a provider or mailbox.
@MainActor
struct MeetingPreparationSession {
    let access: MeetingPreparationAccess
    let providerUnavailableMessage: String?
    let isValid: @MainActor () -> Bool
    let discover: @MainActor (CalendarDisplayEvent, [MailLink], [MailLink], Set<ThreadKey>) async throws -> MeetingPreparationDiscovery
    let summarize: @MainActor (MeetingPreparationCandidate) async throws -> MeetingPreparationThreadReport

    init(service: MeetingPreparationService) {
        access = service.access; providerUnavailableMessage = service.providerUnavailableMessage; isValid = service.isValid
        discover = { try await service.discover(event: $0, included: $1, linked: $2, excluded: $3) }
        summarize = { try await service.summarize($0) }
    }

    init(access: MeetingPreparationAccess, providerUnavailableMessage: String? = nil,
         isValid: @escaping @MainActor () -> Bool,
         discover: @escaping @MainActor (CalendarDisplayEvent, [MailLink], [MailLink], Set<ThreadKey>) async throws -> MeetingPreparationDiscovery,
         summarize: @escaping @MainActor (MeetingPreparationCandidate) async throws -> MeetingPreparationThreadReport) {
        self.access = access; self.providerUnavailableMessage = providerUnavailableMessage; self.isValid = isValid
        self.discover = discover; self.summarize = summarize
    }
}
