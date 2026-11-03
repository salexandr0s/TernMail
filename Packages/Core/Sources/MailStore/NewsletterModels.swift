import Foundation
import GRDB
import MessageContent

public enum NewsletterUnsubscribeStatus: String, Codable, Sendable, CaseIterable {
    case active, requesting, requested, failed, opened, completed
}

/// A mailing list for one receiving account. Counts include only the messages
/// inspected by the newsletter scan, never Gmail's estimated search count.
public struct NewsletterSubscription: Identifiable, Sendable, Equatable {
    public let id: String
    public let accountID: String
    public let senderAddress: String
    public let senderName: String?
    public let listID: String?
    public let latestMessageID: String
    public let latestThreadID: String
    public let latestSubject: String
    public let latestDate: Date
    public let messageCount: Int
    public let unsubscribeURL: URL?
    public let mailtoURL: URL?
    public let oneClickURL: URL?
    public let status: NewsletterUnsubscribeStatus
    public let statusDate: Date?
    public let lastError: String?

    public var canUnsubscribeAutomatically: Bool {
        oneClickURL != nil && (status == .active || status == .failed)
    }

    public init(id: String? = nil, accountID: String, senderAddress: String, senderName: String? = nil,
                listID: String? = nil, latestMessageID: String, latestThreadID: String,
                latestSubject: String = "", latestDate: Date, messageCount: Int,
                unsubscribeURL: URL? = nil, mailtoURL: URL? = nil, oneClickURL: URL? = nil,
                status: NewsletterUnsubscribeStatus = .active, statusDate: Date? = nil, lastError: String? = nil) {
        self.id = id ?? Self.identifier(accountID: accountID, senderAddress: senderAddress, listID: listID)
        self.accountID = accountID
        self.senderAddress = senderAddress
        self.senderName = senderName
        self.listID = listID
        self.latestMessageID = latestMessageID
        self.latestThreadID = latestThreadID
        self.latestSubject = latestSubject
        self.latestDate = latestDate
        self.messageCount = messageCount
        self.unsubscribeURL = unsubscribeURL
        self.mailtoURL = mailtoURL
        self.oneClickURL = oneClickURL
        self.status = status
        self.statusDate = statusDate
        self.lastError = lastError
    }

    public static func identifier(accountID: String, senderAddress: String, listID: String?) -> String {
        // Length prefixes prevent delimiter collisions in untrusted headers.
        [accountID, senderAddress.lowercased(), listID?.lowercased() ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

public struct NewsletterSnapshot: Sendable, Equatable {
    public let accountID: String
    public let subscriptions: [NewsletterSubscription]
    public let scannedMessageCount: Int
    public let displayedScannedMessageCount: Int
    public let isComplete: Bool
    /// A refresh retains the previous scan's rows until the replacement scan
    /// finishes. Its progress counts belong to the new scan.
    public let isRefreshing: Bool
    public let lastScannedAt: Date?
    public let lastError: String?
    public var hasMore: Bool { !isComplete }

    public init(accountID: String, subscriptions: [NewsletterSubscription] = [], scannedMessageCount: Int = 0,
                displayedScannedMessageCount: Int? = nil, isComplete: Bool = false, isRefreshing: Bool = false,
                lastScannedAt: Date? = nil, lastError: String? = nil) {
        self.accountID = accountID
        self.subscriptions = subscriptions
        self.scannedMessageCount = scannedMessageCount
        self.displayedScannedMessageCount = displayedScannedMessageCount ?? scannedMessageCount
        self.isComplete = isComplete
        self.isRefreshing = isRefreshing
        self.lastScannedAt = lastScannedAt
        self.lastError = lastError
    }
}

/// A scan checkpoint, compared inside each page's commit transaction so a
/// canceled or superseded read cannot rewind newer work.
public struct NewsletterScanState: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "newsletterScanState"
    public let accountID: String
    public var generation: String
    public var displayedGeneration: String
    public var nextPageToken: String?
    public var isComplete: Bool
    public var lastScannedAt: Date?
    public var lastError: String?
}

/// One inspected message. A nil subscription means the message carried no
/// supported unsubscribe method; retaining its ID keeps progress deduplicated.
public struct NewsletterMessage: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "newsletterMessage"
    public let accountID: String
    public let generation: String
    public let messageID: String
    public let threadID: String
    public let date: Date
    public let subject: String
    public let senderAddress: String
    public let senderName: String?
    public let listID: String?
    public let subscriptionID: String?
    public let webURL: String?
    public let mailtoURL: String?
    public let oneClickURL: String?

    public init(accountID: String, generation: String, messageID: String, threadID: String, date: Date,
                subject: String, sender: EmailAddress?, options: NewsletterUnsubscribeOptions?) {
        self.accountID = accountID
        self.generation = generation
        self.messageID = messageID
        self.threadID = threadID
        self.date = date
        self.subject = subject
        senderAddress = sender?.normalized ?? ""
        senderName = sender?.name
        listID = options?.listID
        subscriptionID = options.flatMap { value in sender.map {
            NewsletterSubscription.identifier(accountID: accountID, senderAddress: $0.normalized, listID: value.listID)
        } }
        webURL = options?.webURL?.absoluteString
        mailtoURL = options?.mailtoURL?.absoluteString
        oneClickURL = options?.oneClickURL?.absoluteString
    }
}
