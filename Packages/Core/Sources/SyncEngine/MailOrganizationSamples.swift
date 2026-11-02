import Foundation
import GmailAPI
import MailOrganization

/// Progress counts attempted metadata reads, including unavailable messages.
/// The selected total becomes final when reading begins.
public struct MailOrganizationSamplingProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case labels, listing, reading }
    public let stage: Stage
    public let processedCount: Int
    public let selectedCount: Int

    public init(stage: Stage, processedCount: Int = 0, selectedCount: Int = 0) {
        self.stage = stage
        self.processedCount = processedCount
        self.selectedCount = selectedCount
    }
}

/// Account-bound metadata for one organization review. No bodies or attachments.
public struct MailOrganizationSamples: Sendable, Equatable {
    public let accountID: String
    public let messages: [MailOrganizationSample]
    public let existingLabels: [GmailLabel]
    public let selectedCount: Int
    public let unavailableCount: Int
    /// A listing, message, or input bound prevented complete inspection of the window.
    public let isPartial: Bool

    public init(accountID: String, messages: [MailOrganizationSample], existingLabels: [GmailLabel],
                selectedCount: Int, unavailableCount: Int, isPartial: Bool) {
        self.accountID = accountID
        self.messages = messages
        self.existingLabels = existingLabels
        self.selectedCount = selectedCount
        self.unavailableCount = unavailableCount
        self.isPartial = isPartial
    }

    /// Excluding one of a sender's examples must also exclude its broad future
    /// rule. Use the same complete-sample evidence as the action queue.
    public func eligibleRuleSenders(_ candidates: [String], selectedMessageIDs: Set<String>) -> [String] {
        guard !isPartial else { return [] }
        let evidence = OrganizationEvidence(messages: messages.map {
            .init(id: $0.messageID, threadID: $0.threadID, sender: $0.sender, recipients: $0.recipients,
                  date: $0.date, isSent: $0.isSent, hasMailingListHeaders: $0.hasMailingListHeaders,
                  isAutomated: $0.isAutomated)
        })
        return candidates.filter { evidence.supportsRule(sender: $0, classifiedMessageIDs: selectedMessageIDs) }
    }
}

public struct MailOrganizationSample: Sendable, Equatable {
    public let messageID: String
    public let threadID: String
    /// One parsed mailbox address, or empty when From cannot identify one sender.
    public let sender: String
    public let recipients: [String]
    public let subject: String
    public let snippet: String
    public let date: Date?
    public let isSent: Bool
    public let labelIDs: [String]
    public let hasMailingListHeaders: Bool
    public let isAutomated: Bool

    public init(messageID: String, threadID: String, sender: String, recipients: [String], subject: String,
                snippet: String, date: Date?, isSent: Bool, labelIDs: [String],
                hasMailingListHeaders: Bool = false, isAutomated: Bool = false) {
        self.messageID = messageID
        self.threadID = threadID
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.isSent = isSent
        self.labelIDs = labelIDs
        self.hasMailingListHeaders = hasMailingListHeaders
        self.isAutomated = isAutomated
    }
}

public enum MailOrganizationSampleLimits {
    public static let messages = 250
    public static let pages = 10
    public static let batchSize = 25
    public static let subjectBytes = 512
    public static let snippetBytes = 1_024
}
