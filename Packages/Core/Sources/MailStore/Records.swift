import Foundation
import GmailAPI
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
    public var labelListVisibility: String?
    public var messagesTotal: Int?
    public var messagesUnread: Int?

    public init(
        accountID: String, id: String, name: String, isSystem: Bool,
        textColor: String? = nil, backgroundColor: String? = nil,
        threadsTotal: Int? = nil, threadsUnread: Int? = nil,
        labelListVisibility: String? = nil, messagesTotal: Int? = nil, messagesUnread: Int? = nil
    ) {
        self.accountID = accountID
        self.id = id
        self.name = name
        self.isSystem = isSystem
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.threadsTotal = threadsTotal
        self.threadsUnread = threadsUnread
        self.labelListVisibility = labelListVisibility
        self.messagesTotal = messagesTotal
        self.messagesUnread = messagesUnread
    }
}

/// Message metadata as Gmail last reported it. Label membership lives in `message_label`.
public struct MessageRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"

    public var accountID: String
    public var id: String
    public var threadID: String
    public var historyID: Int64
    public var date: Date
    public var snippet: String
    public var sender: String
    /// The From address whose domain passed Gmail's receiver DMARC evaluation.
    /// Nil for old rows, missing evidence, and authentication failures.
    public var verifiedImageSender: String?
    public var recipients: String
    public var cc: String?
    /// Nil until Gmail has supplied this header; an empty string means no Bcc.
    public var bcc: String?
    public var subject: String
    public var sizeEstimate: Int
    /// The `Message-ID` header. Nil for rows cached before replies needed it.
    public var rfcMessageID: String?
    public var inReplyTo: String?
    public var referencesHeader: String?
    public var replyTo: String?
    /// Seconds east of UTC in the `Date` header. Nil when the header names no
    /// zone, and for rows cached before the offset was stored.
    public var dateHeaderOffset: Int?
    /// Whether To or Cc names one of the account's own addresses. The cache
    /// works it out when it stores the message (`upsertMessages`), so a
    /// value given here is replaced.
    public var addressedToMe: Bool

    public init(
        accountID: String, id: String, threadID: String, historyID: Int64, date: Date,
        snippet: String, sender: String, recipients: String, cc: String?, subject: String, sizeEstimate: Int,
        rfcMessageID: String? = nil, inReplyTo: String? = nil, referencesHeader: String? = nil, replyTo: String? = nil,
        dateHeaderOffset: Int? = nil, addressedToMe: Bool = false, bcc: String? = nil,
        verifiedImageSender: String? = nil
    ) {
        self.accountID = accountID
        self.id = id
        self.threadID = threadID
        self.historyID = historyID
        self.date = date
        self.snippet = snippet
        self.sender = sender
        self.verifiedImageSender = verifiedImageSender
        self.recipients = recipients
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.sizeEstimate = sizeEstimate
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.referencesHeader = referencesHeader
        self.replyTo = replyTo
        self.dateHeaderOffset = dateHeaderOffset
        self.addressedToMe = addressedToMe
    }
}

/// A conversation as the thread list shows it. Derived; see `CacheTransaction.rebuildThreads`.
public struct ThreadRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
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
    /// What the list sorts by: `lastDate`, or the wake time of a conversation
    /// a snooze brought back. Stored so `threadLabel_list` can serve the sort.
    var listDate: Date
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

/// A change made locally and not yet confirmed by Gmail: a label change, a
/// draft save, send or discard, or a settings change.
public struct PendingAction: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "pendingAction"

    public enum Kind: String, Codable, Sendable {
        /// `threads.modify` on `threadIDs`.
        case modifyThreads
        /// `messages.batchModify` on `messageIDs`.
        case modifyMessages
        case trashMessages, untrashMessages
        /// Confirmed exact IDs, confined to Spam or Trash by `labelID`.
        case deleteMessages
        case trashThreads
        case untrashThreads
        /// Uploads a local draft's newest revision with `drafts.create` or `drafts.update`.
        case saveDraft
        /// Sends a local draft with `drafts.send`, saving it first if Gmail lacks it.
        case sendDraft
        /// Deletes a local draft, and its Gmail draft when one was saved.
        case discardDraft
        /// `labels.create` for `labelID`, a temporary ID until Gmail answers.
        case createLabel
        /// `labels.patch` with the new name, color or both.
        case updateLabel
        /// `labels.delete`, which Gmail can't undo.
        case deleteLabel
        /// `filters.create`. The payload is `SettingsChange.createFilter`.
        case createFilter
        /// `filters.delete`. The payload is `SettingsChange.deleteFilter`.
        case deleteFilter
        /// `filters.create`, then `filters.delete` of the old filter. The
        /// payload is `SettingsChange.replaceFilter`.
        case replaceFilter
        /// `settings.updateVacation`. The payload is `SettingsChange.vacation`.
        case updateVacation
        /// `sendAs.patch` of a signature. The payload is `SettingsChange.signature`.
        case updateSignature

        /// Draft rows and settings rows each drain apart from label changes,
        /// so a large upload or a slow settings call doesn't hold up archive
        /// or star.
        public var lane: Lane {
            switch self {
            case .modifyThreads, .modifyMessages, .trashThreads, .untrashThreads,
                 .trashMessages, .untrashMessages, .deleteMessages: .labels
            case .createLabel, .updateLabel, .deleteLabel: .labels
            case .saveDraft, .sendDraft, .discardDraft: .compose
            case .createFilter, .deleteFilter, .replaceFilter, .updateVacation, .updateSignature: .settings
            }
        }

        public var changesLabel: Bool {
            switch self {
            case .createLabel, .updateLabel, .deleteLabel: true
            default: false
            }
        }
    }

    /// What a create, update or delete row does to its label.
    public struct LabelChange: Codable, Sendable, Equatable {
        public struct Color: Codable, Sendable, Hashable {
            public var textColor: String
            public var backgroundColor: String

            public init(textColor: String, backgroundColor: String) {
                self.textColor = textColor
                self.backgroundColor = backgroundColor
            }
        }

        public enum ColorChange: Codable, Sendable, Equatable {
            case set(Color)
            case remove
        }

        /// The full name, with "/" between parent and child. Nil when the
        /// name stays as it is.
        public var newName: String?
        public var oldName: String?
        /// Nil when the color stays as it is.
        public var newColor: ColorChange?
        public var oldColor: Color?
        /// For a child renamed with its parent: the parent's label, which is
        /// renamed first.
        public var parentLabelID: String?
        /// The label as Gmail last listed it, for a delete.
        public var deletedLabel: LabelRecord?
        /// For a create Gmail refused because the label was there already:
        /// Tern took that label, so undo must leave it in Gmail.
        public var adoptedExisting: Bool?
        public var newVisibility: LabelListVisibility?
        public var oldVisibility: LabelListVisibility?

        public init(
            newName: String? = nil,
            oldName: String? = nil,
            newColor: ColorChange? = nil,
            oldColor: Color? = nil,
            parentLabelID: String? = nil,
            deletedLabel: LabelRecord? = nil,
            adoptedExisting: Bool? = nil,
            newVisibility: LabelListVisibility? = nil,
            oldVisibility: LabelListVisibility? = nil
        ) {
            self.newName = newName
            self.oldName = oldName
            self.newColor = newColor
            self.oldColor = oldColor
            self.parentLabelID = parentLabelID
            self.deletedLabel = deletedLabel
            self.adoptedExisting = adoptedExisting
            self.newVisibility = newVisibility
            self.oldVisibility = oldVisibility
        }
    }

    /// What a settings row changes in Gmail, with what its undo restores.
    public enum SettingsChange: Codable, Sendable, Equatable {
        /// `filters.create`. `listedIDs` holds the filter IDs Gmail listed
        /// before the first attempt, so a retry can find the filter an
        /// unanswered attempt created.
        case createFilter(filter: GmailFilter, listedIDs: [String]?)
        /// `filters.delete`, with the filter as listed so undo can create it
        /// again. Without an `id`, the row deletes the filter that matches
        /// `filter` and isn't in `listedIDs`, which is how undo finds a
        /// filter whose create may not have answered.
        case deleteFilter(id: String?, filter: GmailFilter, listedIDs: [String]? = nil)
        /// Gmail can't edit a filter, so a replace creates the new one, then
        /// deletes the old. `newID` is set once the create has answered.
        /// Without an `oldID`, the old filter is found by content, as for a
        /// delete without an ID.
        case replaceFilter(oldID: String?, old: GmailFilter, new: GmailFilter, listedIDs: [String]?, newID: String?)
        /// `settings.updateVacation`, sending only `fields` from `new` over
        /// the settings Gmail holds at that moment.
        case vacation(fields: Set<VacationField>, new: VacationSettings, previous: VacationSettings)
        /// `sendAs.patch` of one address's signature.
        case signature(address: String, html: String, previousHTML: String)

        /// The kind of row that carries this change.
        public var kind: Kind {
            switch self {
            case .createFilter: .createFilter
            case .deleteFilter: .deleteFilter
            case .replaceFilter: .replaceFilter
            case .vacation: .updateVacation
            case .signature: .updateSignature
            }
        }
    }

    /// A part of the vacation responder that one edit changes.
    public enum VacationField: String, Codable, Sendable, CaseIterable {
        case enableAutoReply, subject
        /// The plain text and the HTML, which change together.
        case body
        case restrictToContacts, restrictToDomain, startTime, endTime
    }

    public enum Lane: Sendable {
        case labels, compose, settings
    }

    public enum State: String, Codable, Sendable {
        case queued, sending, sent
        /// Retained for explicit Retry or Discard; never projected or claimed.
        case failed
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
    /// The label a create, update or delete row changes.
    public var labelID: String? = nil
    public var labelChange: LabelChange? = nil
    public var settingsChange: SettingsChange? = nil
    /// The history ID Gmail reported for the delivered change. A pass drops the
    /// sent row once its committed cursor reaches it.
    public var confirmedHistoryID: Int64? = nil

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
    /// The ID token's `hd` claim. Nil for personal accounts and while unknown.
    public var hostedDomain: String?
    /// The optional features the user turned on, by name.
    public var enabledFeatures: [String]
    /// Whether replies and forwards get the From address's signature.
    public var signatureOnReplies: Bool

    public init(
        id: String, email: String, displayName: String?, grantedScopes: [String], addedAt: Date,
        hostedDomain: String? = nil, enabledFeatures: [String] = [], signatureOnReplies: Bool = false
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.grantedScopes = grantedScopes
        self.addedAt = addedAt
        self.hostedDomain = hostedDomain
        self.enabledFeatures = enabledFeatures
        self.signatureOnReplies = signatureOnReplies
    }
}
