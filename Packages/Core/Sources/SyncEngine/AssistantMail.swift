import Foundation
import MailStore

/// Bounded mail content returned to an assistant, without changing read state.
public struct AssistantThread: Sendable, Encodable {
    public let accountID: String
    public let threadID: String
    public let messages: [AssistantMessage]
    public let totalMessages: Int
    public let truncated: Bool
    public let snippet: String
    public let labelIDs: [String]
}

public struct AssistantMessage: Sendable, Encodable {
    public let messageID: String
    public let threadID: String
    public let sender: String
    public let recipients: String
    public let subject: String
    public let date: Date?
    public let text: String
    public let attachments: [AttachmentRecord]
    public let truncated: Bool
    public let limitations: [String]
}

public struct AssistantAttachment: Sendable {
    public let accountID: String
    public let threadID: String
    public let messageID: String
    public let partID: String
    public let filename: String
    public let mimeType: String
    public let data: Data
}

public enum AssistantMailError: Error, LocalizedError, Equatable {
    case invalidTarget
    case attachmentTooLarge
    case unavailable
    case accessChanged

    public var errorDescription: String? {
        switch self {
        case .invalidTarget: "The requested mail item is not available in this scope."
        case .attachmentTooLarge: "This attachment exceeds the assistant's 5 MB limit."
        case .unavailable: "The requested message or attachment is no longer available."
        case .accessChanged: "Mail access changed. Start a new assistant request."
        }
    }
}

public enum AssistantMailLimits {
    public static let messagesPerThread = 50
    public static let charactersPerMessage = 20_000
    public static let charactersPerThread = 100_000
    public static let attachmentBytes = 5_000_000
    public static let bodyBytes = 1_000_000
    public static let attachmentsPerMessage = 100
}
