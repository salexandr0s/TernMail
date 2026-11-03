import Foundation
import GRDB

public enum CommitmentDirection: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case owedByMe, waitingFor
}

public enum CommitmentStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case open, completed, dismissed
}

public enum CommitmentReminderKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case noReply, unresolved
}

/// User-accepted work lives in config.sqlite and survives eviction of its source mail.
public struct CommitmentRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "commitment"

    public var accountID: String
    public var id: String
    public var threadID: String
    public var sourceMessageID: String
    public var sourceMessageDate: Date
    public var sourceSubject: String
    public var title: String
    public var ownerName: String?
    public var ownerEmail: String?
    public var direction: CommitmentDirection
    public var status: CommitmentStatus
    public var dueAt: Date?
    public var deferredUntil: Date?
    public var acceptanceKey: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: Int

    public init(accountID: String, id: String = UUID().uuidString, threadID: String,
                sourceMessageID: String, sourceMessageDate: Date, sourceSubject: String,
                title: String, ownerName: String? = nil, ownerEmail: String? = nil,
                direction: CommitmentDirection, status: CommitmentStatus = .open,
                dueAt: Date? = nil, deferredUntil: Date? = nil, acceptanceKey: String? = nil,
                createdAt: Date = Date(), updatedAt: Date? = nil, revision: Int = 0) {
        self.accountID = accountID; self.id = id; self.threadID = threadID
        self.sourceMessageID = sourceMessageID; self.sourceMessageDate = sourceMessageDate
        self.sourceSubject = sourceSubject; self.title = title
        self.ownerName = ownerName; self.ownerEmail = ownerEmail; self.direction = direction
        self.status = status; self.dueAt = dueAt; self.deferredUntil = deferredUntil; self.acceptanceKey = acceptanceKey
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.revision = revision
    }
}

/// A reply can satisfy a reminder without resolving the underlying commitment.
public struct CommitmentReminderRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "commitmentReminder"

    public var accountID: String
    public var commitmentID: String
    public var kind: CommitmentReminderKind
    public var remindAt: Date
    public var baselineMessageID: String
    public var baselineDate: Date
    public var baselineHistoryID: Int64?
    public var receivedReplyMessageID: String?
    public var receivedReplyAt: Date?
    public var deliveredAt: Date?
    public var notificationID: String?
    public var revision: Int

    public var isPending: Bool { deliveredAt == nil && receivedReplyMessageID == nil }

    public init(accountID: String, commitmentID: String, kind: CommitmentReminderKind,
                remindAt: Date, baselineMessageID: String, baselineDate: Date,
                baselineHistoryID: Int64? = nil, receivedReplyMessageID: String? = nil,
                receivedReplyAt: Date? = nil, deliveredAt: Date? = nil,
                notificationID: String? = nil, revision: Int = 0) {
        self.accountID = accountID; self.commitmentID = commitmentID; self.kind = kind
        self.remindAt = remindAt; self.baselineMessageID = baselineMessageID; self.baselineDate = baselineDate
        self.baselineHistoryID = baselineHistoryID; self.receivedReplyMessageID = receivedReplyMessageID
        self.receivedReplyAt = receivedReplyAt; self.deliveredAt = deliveredAt
        self.notificationID = notificationID; self.revision = revision
    }
}

public struct CommitmentEntry: Sendable, Equatable, Identifiable {
    public var record: CommitmentRecord
    public var reminders: [CommitmentReminderRecord]

    public var id: String { "\(record.accountID.utf8.count):\(record.accountID)\(record.id)" }

    public init(record: CommitmentRecord, reminders: [CommitmentReminderRecord] = []) {
        self.record = record; self.reminders = reminders
    }
}

public enum CommitmentStoreError: Error, LocalizedError, Equatable, Sendable {
    case unavailableAccount, notFound, conflict, invalidRecord

    public var errorDescription: String? {
        switch self {
        case .unavailableAccount: "This account is no longer available."
        case .notFound: "This follow-up is no longer available."
        case .conflict: "This follow-up changed. Reload it before saving your changes."
        case .invalidRecord: "Check the follow-up details and try again."
        }
    }
}
