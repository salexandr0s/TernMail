import Foundation
import MailOrganization

/// Metadata and short excerpts from one account. These stay in memory for the review.
public struct OrganizationEmail: Equatable, Sendable {
    public let id: String
    public let threadID: String
    /// A bare address when parsing succeeds; otherwise the original From header.
    public let sender: String
    public let recipients: [String]
    public let subject: String
    public let snippet: String
    public let date: Date?
    public let isSent: Bool
    public let labelNames: [String]
    public let hasMailingListHeaders: Bool
    public let isAutomated: Bool

    public init(id: String, threadID: String, sender: String, recipients: [String], subject: String,
                snippet: String, date: Date?, isSent: Bool, labelNames: [String],
                hasMailingListHeaders: Bool = false, isAutomated: Bool = false) {
        self.id = id; self.threadID = threadID; self.sender = sender; self.recipients = recipients
        self.subject = subject; self.snippet = snippet; self.date = date; self.isSent = isSent
        self.labelNames = labelNames
        self.hasMailingListHeaders = hasMailingListHeaders
        self.isAutomated = isAutomated
    }

    var evidence: OrganizationMessageEvidence {
        .init(id: id, threadID: threadID, sender: sender, recipients: recipients, date: date,
              isSent: isSent, hasMailingListHeaders: hasMailingListHeaders, isAutomated: isAutomated)
    }
}

public struct OrganizationCategory: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case topic, action, waiting }
    public let id: String
    public var name: String
    public let explanation: String
    public let kind: Kind
    public let messageIDs: [String]
    /// Exact addresses supported by repeated incoming examples. The mail layer
    /// constructs Gmail criteria; model output never supplies a search query.
    public let ruleSenders: [String]

    public init(id: String, name: String, explanation: String, kind: Kind,
                messageIDs: [String], ruleSenders: [String]) {
        self.id = id; self.name = name; self.explanation = explanation; self.kind = kind
        self.messageIDs = messageIDs; self.ruleSenders = ruleSenders
    }
}

public struct OrganizationPlan: Codable, Equatable, Sendable {
    public let categories: [OrganizationCategory]
    public let analyzedCount: Int

    public init(categories: [OrganizationCategory], analyzedCount: Int) {
        self.categories = categories; self.analyzedCount = analyzedCount
    }
}

public enum MailOrganizationError: Error, Equatable, LocalizedError, Sendable {
    case invalidInput, invalidResponse, responseLimit, interrupted

    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Tern could not prepare these messages for analysis. Refresh and try again."
        case .invalidResponse: "ChatGPT returned categories Tern could not validate. Try the analysis again."
        case .responseLimit: "The category suggestions exceeded Tern's size limit. Try the analysis again."
        case .interrupted: "The analysis stopped before ChatGPT finished. Try again."
        }
    }
}
