import Foundation
import GRDB

public enum MailAnalyticsPeriod: String, CaseIterable, Sendable {
    case month, quarter, year, allTime

    public var title: String {
        switch self {
        case .month: "30 days"
        case .quarter: "90 days"
        case .year: "12 months"
        case .allTime: "All history"
        }
    }
}

public struct MailAnalyticsQuery: Sendable, Equatable {
    public var accountIDs: [String]
    public var contactAddress: String?
    public var period: MailAnalyticsPeriod
    public var now: Date
    public var timeZone: TimeZone

    public init(accountIDs: [String], contactAddress: String? = nil, period: MailAnalyticsPeriod = .year,
                now: Date = .now, timeZone: TimeZone = .current) {
        self.accountIDs = Array(Set(accountIDs)).sorted()
        self.contactAddress = contactAddress?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.period = period
        self.now = now
        self.timeZone = timeZone
    }
}

public enum MailAnalyticsDirection: String, Codable, Sendable {
    case sent, received
}

public enum MailAnalyticsBucketUnit: String, Sendable {
    case day, month, year

    public var calendarComponent: Calendar.Component {
        switch self {
        case .day: .day
        case .month: .month
        case .year: .year
        }
    }
}

public struct MailAnalyticsBucket: Sendable, Equatable, Identifiable {
    public let date: Date
    public let sentCount: Int
    public let receivedCount: Int
    public var id: Date { date }

    public init(date: Date, sentCount: Int, receivedCount: Int) {
        self.date = date; self.sentCount = sentCount; self.receivedCount = receivedCount
    }
}

public struct MailAnalyticsCorrespondent: Sendable, Equatable, Identifiable {
    public let address: String
    public let name: String?
    public let sentCount: Int
    public let receivedCount: Int
    public let lastContactAt: Date
    public var id: String { address }
    public var totalCount: Int { sentCount + receivedCount }

    public init(address: String, name: String? = nil, sentCount: Int, receivedCount: Int, lastContactAt: Date) {
        self.address = address; self.name = name; self.sentCount = sentCount
        self.receivedCount = receivedCount; self.lastContactAt = lastContactAt
    }
}

public struct MailAnalyticsMessage: Sendable, Equatable, Identifiable {
    public let accountID: String
    public let messageID: String
    public let threadID: String
    public let date: Date
    public let subject: String
    public let sender: String
    public let direction: MailAnalyticsDirection
    public var id: String { "\(accountID.utf8.count):\(accountID)\(messageID.utf8.count):\(messageID)" }

    public init(accountID: String, messageID: String, threadID: String, date: Date, subject: String,
                sender: String, direction: MailAnalyticsDirection) {
        self.accountID = accountID; self.messageID = messageID; self.threadID = threadID
        self.date = date; self.subject = subject; self.sender = sender; self.direction = direction
    }
}

/// A completed listing is a dated snapshot. Gmail can change while its pages are read.
public struct MailAnalyticsCoverage: Sendable, Equatable, Identifiable {
    public let accountID: String
    public let indexedMessageCount: Int
    public let historyLoadedAt: Date?
    public let nextPageToken: String?
    public let isComplete: Bool
    public let lastError: String?
    public var id: String { accountID }

    public init(accountID: String, indexedMessageCount: Int, historyLoadedAt: Date? = nil,
                nextPageToken: String? = nil, isComplete: Bool = false, lastError: String? = nil) {
        self.accountID = accountID; self.indexedMessageCount = indexedMessageCount
        self.historyLoadedAt = historyLoadedAt; self.nextPageToken = nextPageToken
        self.isComplete = isComplete; self.lastError = lastError
    }
}

public struct MailAnalyticsProfileSource: Sendable, Equatable, Identifiable {
    public let accountID: String
    public let messageID: String
    public let date: Date
    public let plainText: String?
    public let html: String?
    public var id: String { "\(accountID.utf8.count):\(accountID)\(messageID.utf8.count):\(messageID)" }

    public init(accountID: String, messageID: String, date: Date, plainText: String? = nil, html: String? = nil) {
        self.accountID = accountID; self.messageID = messageID; self.date = date
        self.plainText = plainText; self.html = html
    }
}

public struct MailAnalyticsSnapshot: Sendable, Equatable {
    /// Counts and activity use the selected period. Milestone dates use all indexed history.
    public let sentCount: Int
    public let receivedCount: Int
    public let threadCount: Int
    public let firstReceivedAt: Date?
    public let firstSentAt: Date?
    public let lastContactAt: Date?
    public let bucketUnit: MailAnalyticsBucketUnit
    public let buckets: [MailAnalyticsBucket]
    public let correspondents: [MailAnalyticsCorrespondent]
    public let recentMessages: [MailAnalyticsMessage]
    public let coverage: [MailAnalyticsCoverage]
    public let profileSources: [MailAnalyticsProfileSource]
    public var totalCount: Int { sentCount + receivedCount }

    public init(sentCount: Int, receivedCount: Int, threadCount: Int, firstReceivedAt: Date? = nil,
                firstSentAt: Date? = nil, lastContactAt: Date? = nil, bucketUnit: MailAnalyticsBucketUnit = .month,
                buckets: [MailAnalyticsBucket] = [], correspondents: [MailAnalyticsCorrespondent] = [],
                recentMessages: [MailAnalyticsMessage] = [], coverage: [MailAnalyticsCoverage] = [],
                profileSources: [MailAnalyticsProfileSource] = []) {
        self.sentCount = sentCount; self.receivedCount = receivedCount; self.threadCount = threadCount
        self.firstReceivedAt = firstReceivedAt; self.firstSentAt = firstSentAt; self.lastContactAt = lastContactAt
        self.bucketUnit = bucketUnit; self.buckets = buckets; self.correspondents = correspondents
        self.recentMessages = recentMessages; self.coverage = coverage; self.profileSources = profileSources
    }
}

/// The page checkpoint and rows commit together. `generation` rejects old requests after a restart.
public struct MailAnalyticsIndexState: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mailAnalyticsState"
    public var accountID: String
    public var generation: String
    public var nextPageToken: String?
    public var historyLoadedAt: Date?
    public var isComplete: Bool
    public var lastError: String?

    public init(accountID: String, generation: String = UUID().uuidString, nextPageToken: String? = nil,
                historyLoadedAt: Date? = nil, isComplete: Bool = false, lastError: String? = nil) {
        self.accountID = accountID
        self.generation = generation
        self.nextPageToken = nextPageToken
        self.historyLoadedAt = historyLoadedAt
        self.isComplete = isComplete
        self.lastError = lastError
    }
}

struct MailAnalyticsRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mailAnalyticsMessage"
    var accountID: String
    var messageID: String
    var threadID: String
    var historyID: Int64
    var date: Date
    var subject: String
    var sender: String
    var senderAddress: String
    var recipients: String
    var cc: String?
    var labelIDs: [String]
    var direction: MailAnalyticsDirection
    var isIncluded: Bool
    var generation: String?
}
