import Foundation
import MailStore

struct FollowUpSource: Sendable, Equatable {
    var accountID: String
    var threadID: String
    var messageID: String
    var date: Date
    var subject: String
    var sender: String
    var recipients: String
    var cc: String?
    var historyID: Int64

    init(record: MessageRecord) {
        accountID = record.accountID; threadID = record.threadID; messageID = record.id
        date = record.date; subject = record.subject; sender = record.sender
        recipients = record.recipients; cc = record.cc; historyID = record.historyID
    }

    init(commitment: CommitmentRecord) {
        accountID = commitment.accountID; threadID = commitment.threadID
        messageID = commitment.sourceMessageID; date = commitment.sourceMessageDate
        subject = commitment.sourceSubject; sender = ""; recipients = ""; cc = nil; historyID = 0
    }
}

struct FollowUpEditValues: Sendable, Equatable {
    var title: String
    var ownerName: String
    var ownerEmail: String
    var direction: CommitmentDirection
    var dueAt: Date?
    var reminderKind: CommitmentReminderKind?
    var remindAt: Date?
}

struct FollowUpEditorRequest: Identifiable, Sendable, Equatable {
    let id = UUID()
    var source: FollowUpSource
    var existing: CommitmentEntry?
    var values: FollowUpEditValues
    var acceptanceKey: String?
}

enum FollowUpReplyCheckState: Equatable {
    case checking
    case checked(Date)
    case unavailable
}

struct FollowUpThreadSnapshot: Sendable {
    var accountID: String
    var threadID: String
    var messages: [MessageRecord]
    var labels: [String: Set<String>]
    var ownAddresses: Set<String>
    var checkedAt: Date
}

enum FollowUpModelError: Error {
    case unavailable, invalidSource, invalidEdit
}
