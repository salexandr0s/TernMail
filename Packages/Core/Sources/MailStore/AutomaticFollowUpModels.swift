import Foundation
import GRDB

/// The caller verifies that this is the latest unanswered SENT message in its thread.
public struct AutomaticFollowUpCandidate: Sendable, Equatable {
    public let accountID: String
    public let threadID: String
    public let outgoingMessageID: String
    public let outgoingDate: Date
    public let sourceSubject: String
    public let title: String
    public let ownerName: String?
    public let ownerEmail: String?
    public let baselineHistoryID: Int64?

    public init(accountID: String, threadID: String, outgoingMessageID: String, outgoingDate: Date,
                sourceSubject: String, title: String, ownerName: String? = nil, ownerEmail: String? = nil,
                baselineHistoryID: Int64? = nil) {
        self.accountID = accountID; self.threadID = threadID; self.outgoingMessageID = outgoingMessageID
        self.outgoingDate = outgoingDate; self.sourceSubject = sourceSubject; self.title = title
        self.ownerName = ownerName; self.ownerEmail = ownerEmail; self.baselineHistoryID = baselineHistoryID
    }
}

/// A retained mapping prevents automatic tracking from recreating manually corrected or closed work.
public struct AutomaticFollowUpRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "automaticFollowUp"
    public internal(set) var accountID: String
    public internal(set) var threadID: String
    public internal(set) var commitmentID: String
    public internal(set) var managed: Bool
    public internal(set) var latestOutgoingMessageID: String
    public internal(set) var latestOutgoingDate: Date
    public internal(set) var delayDays: Int
    public internal(set) var eligibleForAlerts: Bool
    public internal(set) var scheduleEnabled: Bool
    public internal(set) var revision: Int
}

public struct AutomaticFollowUpMutation: Sendable, Equatable {
    public let entry: CommitmentEntry?
    public let removedNotificationIDs: Set<String>
}

public enum AutomaticFollowUpDraftState: String, Codable, Sendable, DatabaseValueConvertible {
    case reserved, prepared, blocked, failed, uncertain
}

/// Even a reservation left by a crash prevents another draft for the same outgoing message.
public struct AutomaticFollowUpDraftReceipt: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "automaticFollowUpDraft"
    public internal(set) var accountID: String
    public internal(set) var threadID: String
    public internal(set) var commitmentID: String
    public internal(set) var outgoingMessageID: String
    public internal(set) var claimID: String
    public internal(set) var draftID: String
    public internal(set) var state: AutomaticFollowUpDraftState
    public internal(set) var createdAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var automationRevision: Int
}
