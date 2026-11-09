import Foundation

public enum TodayScope: Codable, Hashable, Sendable {
    case all
    case profile(String)

    var storageKey: String {
        switch self {
        case .all: "all"
        case .profile(let id): "profile:\(id)"
        }
    }

    var profileID: String? {
        switch self {
        case .all: nil
        case .profile(let id): id
        }
    }
}

public struct TodayReminderSnapshot: Codable, Equatable, Sendable {
    public let kind: CommitmentReminderKind
    public let remindAt: Date
    public let baselineMessageID: String
    public let baselineDate: Date
    public let receivedReplyMessageID: String?
    public let receivedReplyAt: Date?

    public init(reminder: CommitmentReminderRecord) {
        kind = reminder.kind; remindAt = reminder.remindAt
        baselineMessageID = reminder.baselineMessageID; baselineDate = reminder.baselineDate
        receivedReplyMessageID = reminder.receivedReplyMessageID; receivedReplyAt = reminder.receivedReplyAt
    }
}

/// The meaning shown in a briefing, independent of notification delivery and database revisions.
public struct TodayCommitmentSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let accountID: String
    public let commitmentID: String
    public let threadID: String
    public let sourceMessageID: String
    public let sourceMessageDate: Date
    public let sourceSubject: String
    public let title: String
    public let ownerName: String?
    public let ownerEmail: String?
    public let direction: CommitmentDirection
    public let status: CommitmentStatus
    public let dueAt: Date?
    public let deferredUntil: Date?
    public let reminders: [TodayReminderSnapshot]

    public var id: String { "\(accountID.utf8.count):\(accountID)\(commitmentID)" }

    public init(entry: CommitmentEntry) {
        let record = entry.record
        accountID = record.accountID; commitmentID = record.id; threadID = record.threadID
        sourceMessageID = record.sourceMessageID; sourceMessageDate = record.sourceMessageDate
        sourceSubject = record.sourceSubject; title = record.title
        ownerName = record.ownerName; ownerEmail = record.ownerEmail
        direction = record.direction; status = record.status; dueAt = record.dueAt
        deferredUntil = record.deferredUntil
        reminders = entry.reminders.sorted { $0.kind.rawValue < $1.kind.rawValue }.map(TodayReminderSnapshot.init)
    }
}

public struct TodayVisitBaseline: Equatable, Sendable {
    public let scope: TodayScope
    public let accountIDs: Set<String>
    public let initializedAccountIDs: Set<String>
    public let snapshots: [String: TodayCommitmentSnapshot]

    public init(scope: TodayScope, accountIDs: Set<String>, initializedAccountIDs: Set<String>,
                snapshots: [String: TodayCommitmentSnapshot]) {
        self.scope = scope; self.accountIDs = accountIDs
        self.initializedAccountIDs = initializedAccountIDs; self.snapshots = snapshots
    }
}

public struct TodayVisitAcknowledgement: Equatable, Sendable {
    public let initializedAccountIDs: Set<String>
    public let acknowledgedIDs: Set<String>

    public init(initializedAccountIDs: Set<String>, acknowledgedIDs: Set<String>) {
        self.initializedAccountIDs = initializedAccountIDs; self.acknowledgedIDs = acknowledgedIDs
    }
}

public enum TodayVisitStoreError: Error, Equatable, Sendable {
    case unavailableScope, invalidSnapshot
}
