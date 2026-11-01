import Foundation
import TernAI

/// Permission and model identity for compose. Mailbox selection is deliberately
/// absent: changing the reader must not change an open draft's conversation.
struct ComposeAssistantAccess: Equatable {
    let scope: AssistantScopeSnapshot
    let modelID: String
    let modelReady: Bool
    let writingStyleEnabled: [String: Bool]
    let revision: Int
    let styleAccessRevision: Int
}

/// A compose window owns its tools and history while sharing the app's provider
/// and access settings. Neither this session nor its tools can save or send mail.
@MainActor
struct ComposeAssistantSession {
    let provider: any AIProvider
    let model: String
    let scope: AssistantScopeSnapshot
    let tools: AssistantToolSession
    let isValid: @MainActor () -> Bool
    let writingStyle: @MainActor () async throws -> String

    static let mailToolNames: Set<String> = ["search_mail", "read_thread", "read_attachment"]
    static let calendarToolNames: Set<String> = [
        "list_calendars", "read_calendar_events", "read_calendar_event",
        "check_availability", "check_requested_availability",
    ]
    static let readToolNames = mailToolNames.union(calendarToolNames)

    enum SessionError: Error, LocalizedError {
        case mailAccessRequired, accountUnavailable, learningStyle

        var errorDescription: String? {
            switch self {
            case .mailAccessRequired:
                "Enable assistant access for this message's mail account in Assistant Settings."
            case .accountUnavailable:
                "Sign in to this message's mail account to use the assistant."
            case .learningStyle:
                "Your writing style is still being learned. Wait for it to finish, then try again."
            }
        }
    }
}
