import Foundation

/// A bounded, account-specific view of sent writing. No headers or recipients
/// are included in the text supplied for style analysis.
public struct AssistantWritingSamples: Sendable, Equatable {
    public let accountID: String
    public let requestedCount: Int
    public let selectedCount: Int
    /// Full responses whose message/thread identity and SENT label were verified.
    public let inspectedCount: Int
    public let samples: [AssistantWritingSample]
    /// Inspected messages omitted because their text was unavailable or unsuitable.
    public let skippedCount: Int
    public let failures: [AssistantWritingSampleFailure]
    /// Requested-window content was omitted or shortened by a limit or failure.
    public let truncated: Bool
    /// Older mail exists outside the selected window, or listing was incomplete.
    public let hasMoreSentMail: Bool

    public init(accountID: String, requestedCount: Int, selectedCount: Int, inspectedCount: Int,
                samples: [AssistantWritingSample], skippedCount: Int,
                failures: [AssistantWritingSampleFailure], truncated: Bool, hasMoreSentMail: Bool) {
        self.accountID = accountID; self.requestedCount = requestedCount
        self.selectedCount = selectedCount; self.inspectedCount = inspectedCount
        self.samples = samples; self.skippedCount = skippedCount; self.failures = failures
        self.truncated = truncated; self.hasMoreSentMail = hasMoreSentMail
    }
}

public struct AssistantWritingSample: Sendable, Equatable {
    public let messageID: String
    public let date: Date?
    public let text: String
    public let truncated: Bool

    public init(messageID: String, date: Date?, text: String, truncated: Bool) {
        self.messageID = messageID; self.date = date; self.text = text; self.truncated = truncated
    }
}

public struct AssistantWritingSampleFailure: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case listingUnavailable, pageLimit, repeatedPageToken, invalidListing
        case messageUnavailable, invalidMessage, bodyUnavailable, bodyTooLarge
        case bodySizeUnknown, bodyPartsLimited, excerptLimit
    }
    public let messageID: String?
    public let reason: Reason

    public init(messageID: String? = nil, reason: Reason) {
        self.messageID = messageID; self.reason = reason
    }
}

public enum AssistantWritingSampleLimits {
    public static let messages = 100
    public static let pages = 5
    public static let batchSize = 10
    public static let bodyPartsPerMessage = 2
    public static let bodyBytesPerMessage = 131_072
    public static let totalBodyBytes = 2_000_000
    public static let bytesPerSample = 2_048
    public static let totalSampleBytes = 81_920
}
