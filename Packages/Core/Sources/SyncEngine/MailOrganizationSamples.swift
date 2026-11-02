import Foundation
import GmailAPI

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

    public init(messageID: String, threadID: String, sender: String, recipients: [String], subject: String,
                snippet: String, date: Date?, isSent: Bool, labelIDs: [String]) {
        self.messageID = messageID
        self.threadID = threadID
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.isSent = isSent
        self.labelIDs = labelIDs
    }
}

public enum MailOrganizationSampleLimits {
    public static let messages = 250
    public static let pages = 10
    public static let batchSize = 25
    public static let subjectBytes = 512
    public static let snippetBytes = 1_024
}
