import Foundation
import GRDB

/// Gmail system label IDs, plus the virtual All Mail label this app derives.
public enum SystemLabel {
    public static let inbox = "INBOX"
    public static let unread = "UNREAD"
    public static let starred = "STARRED"
    public static let important = "IMPORTANT"
    public static let sent = "SENT"
    public static let draft = "DRAFT"
    public static let spam = "SPAM"
    public static let trash = "TRASH"
    /// Not a Gmail label: every thread with a message outside Spam and Trash.
    public static let allMail = "TERN_ALL_MAIL"
}

// MARK: cache.sqlite

public struct LabelRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "label"

    public var accountID: String
    public var id: String
    public var name: String
    public var isSystem: Bool
    public var textColor: String?
    public var backgroundColor: String?
    public var threadsTotal: Int?
    public var threadsUnread: Int?

    public init(
        accountID: String, id: String, name: String, isSystem: Bool,
        textColor: String? = nil, backgroundColor: String? = nil,
        threadsTotal: Int? = nil, threadsUnread: Int? = nil
    ) {
        self.accountID = accountID
        self.id = id
        self.name = name
        self.isSystem = isSystem
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
    }
}

/// Message metadata as Gmail last reported it. Label membership lives in `message_label`.
public struct MessageRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"

    public var accountID: String
    public var id: String
    public var threadID: String
    public var historyID: Int64
    public var date: Date
    public var snippet: String
    public var sender: String
    public var recipients: String
    public var cc: String?
    public var subject: String
    public var sizeEstimate: Int
    /// The `Message-ID` header. Nil for rows cached before replies needed it.
    public var rfcMessageID: String?
    public var inReplyTo: String?
    public var referencesHeader: String?
    public var replyTo: String?

    public init(
        accountID: String, id: String, threadID: String, historyID: Int64, date: Date,
        snippet: String, sender: String, recipients: String, cc: String?, subject: String, sizeEstimate: Int,
        rfcMessageID: String? = nil, inReplyTo: String? = nil, referencesHeader: String? = nil, replyTo: String? = nil
    ) {
        self.accountID = accountID
        self.id = id
        self.threadID = threadID
        self.historyID = historyID
        self.date = date
        self.snippet = snippet
        self.sender = sender
        self.recipients = recipients
        self.cc = cc
        self.subject = subject
        self.sizeEstimate = sizeEstimate
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.referencesHeader = referencesHeader
        self.replyTo = replyTo
    }
}

/// A conversation as the thread list shows it. Derived; see `CacheTransaction.rebuildThreads`.
public struct ThreadRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "thread"

    public var accountID: String
    public var id: String
    public var lastDate: Date
    public var subject: String
    public var snippet: String
    public var participants: String
    public var messageCount: Int
    public var isUnread: Bool
    public var isStarred: Bool
}

struct ThreadLabelRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "threadLabel"

    var accountID: String
    var threadID: String
    var labelID: String
    var lastDate: Date
}

/// Decoded body parts of one message, stored raw and sanitized when rendered.
public struct MessageBodyRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messageBody"

    public var accountID: String
    public var messageID: String
    public var html: String?
    public var plainText: String?
    public var fetchedAt: Date

    public init(accountID: String, messageID: String, html: String?, plainText: String?, fetchedAt: Date) {
        self.accountID = accountID
        self.messageID = messageID
        self.html = html
        self.plainText = plainText
        self.fetchedAt = fetchedAt
    }
}

public struct SyncStateRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "syncState"

    public var accountID: String
    public var historyID: Int64
    public var lastFullSyncAt: Date
}

/// A label change made locally and not yet confirmed by a history pass.
public struct PendingAction: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "pendingAction"

    public enum Kind: String, Codable, Sendable {
        /// `threads.modify` on `threadIDs`.
        case modifyThreads
        /// `messages.batchModify` on `messageIDs`.
        case modifyMessages
        case trashThreads
        case untrashThreads
    }

    public enum State: String, Codable, Sendable {
        case queued, sending, sent
        /// Undone while its send was in flight. The sender deletes it once the
        /// request finishes, and the inverse goes out after it.
        case undone
    }

    /// What the action changed on one message, relative to what the user saw.
    public struct LabelDiff: Codable, Sendable, Hashable {
        public var added: [String]
        public var removed: [String]

        public init(added: [String], removed: [String]) {
            self.added = added
            self.removed = removed
        }
    }

    public var id: Int64?
    public var accountID: String
    public var kind: Kind
    public var threadIDs: [String]
    /// Targets for modifyMessages. For trashThreads, the messages that
    /// were already in Trash, to preserve their membership when undoing.
    public var messageIDs: [String]
    public var addLabelIDs: [String]
    public var removeLabelIDs: [String]
    /// Keyed by message ID. Undo builds its inverse from this.
    public var diff: [String: LabelDiff]
    public var state: State
    public var attempts: Int
    public var lastError: String?
    public var createdAt: Date
    /// The sender leaves the row alone until this date (undo hold, then backoff).
    public var notBefore: Date
    public var sentAt: Date?
    /// The compose window's draft, for draft rows. Nil for label changes.
    public var localDraftID: String? = nil

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: config.sqlite

public struct AccountRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "account"

    /// Google's stable user ID (the ID token's `sub`).
    public var id: String
    public var email: String
    public var displayName: String?
    public var grantedScopes: [String]
    public var addedAt: Date

    public init(id: String, email: String, displayName: String?, grantedScopes: [String], addedAt: Date) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.grantedScopes = grantedScopes
        self.addedAt = addedAt
    }
}
