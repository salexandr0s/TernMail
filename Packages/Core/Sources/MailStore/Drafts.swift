import Foundation
import GRDB
import MessageContent

/// The part of a local draft the compose window edits.
public struct DraftContent: Sendable, Equatable {
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var body: ComposeDocument

    public init(
        to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
        subject: String = "", body: ComposeDocument = ComposeDocument()
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }
}

/// A message in a compose window. It is stored here first and reaches Gmail
/// through queued saves, so a crash or quit never loses it.
public struct LocalDraft: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "localDraft"

    public enum Kind: String, Codable, Sendable {
        case new, reply, replyAll, forward
        /// A draft that already exists in Gmail, opened from the Drafts label.
        case edit
    }

    public enum State: String, Codable, Sendable {
        case editing
        /// A send is queued or under way. Edits wait until it is undone or fails.
        case sending
        /// A discard is queued. Undo returns the draft to editing.
        case discarding
    }

    public var id: String
    public var accountID: String
    /// Nil until the first save reaches Gmail.
    public var gmailDraftID: String?
    /// The Gmail message our last save created. Each `drafts.update` replaces it.
    public var savedMessageID: String?
    public var threadID: String?
    public var kind: Kind
    /// The message a reply or forward answers.
    public var sourceMessageID: String?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var body: ComposeDocument
    /// The quoted original, or an imported draft's quote, sent unchanged after the new text.
    public var quotedHTML: String?
    public var quotedPlainText: String?
    public var rfcMessageID: String
    public var inReplyTo: String?
    public var references: [String]
    /// Raised by every edit. A save uploads one revision and records it in `savedRevision`.
    public var revision: Int
    public var savedRevision: Int
    public var state: State
    /// Gmail's reason for refusing the last send, shown until the next send.
    public var sendError: String?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, accountID, gmailDraftID, savedMessageID, threadID, kind, sourceMessageID
        case to = "toAddresses", cc = "ccAddresses", bcc = "bccAddresses"
        case subject, body, quotedHTML, quotedPlainText, rfcMessageID, inReplyTo
        case references = "referencesHeader"
        case revision, savedRevision, state, sendError, createdAt, updatedAt
    }

    public init(
        id: String = UUID().uuidString,
        accountID: String,
        kind: Kind,
        content: DraftContent = DraftContent(),
        rfcMessageID: String,
        gmailDraftID: String? = nil,
        savedMessageID: String? = nil,
        threadID: String? = nil,
        sourceMessageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        quotedHTML: String? = nil,
        quotedPlainText: String? = nil,
        now: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.gmailDraftID = gmailDraftID
        self.savedMessageID = savedMessageID
        self.threadID = threadID
        self.kind = kind
        self.sourceMessageID = sourceMessageID
        to = content.to
        cc = content.cc
        bcc = content.bcc
        subject = content.subject
        body = content.body
        self.quotedHTML = quotedHTML
        self.quotedPlainText = quotedPlainText
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.references = references
        revision = 0
        savedRevision = 0
        state = .editing
        sendError = nil
        createdAt = now
        updatedAt = now
    }

    public var content: DraftContent {
        get { DraftContent(to: to, cc: cc, bcc: bcc, subject: subject, body: body) }
        set {
            to = newValue.to
            cc = newValue.cc
            bcc = newValue.bcc
            subject = newValue.subject
            body = newValue.body
        }
    }

    public var hasUnsavedChanges: Bool { revision > savedRevision }
}

/// A file attached in a compose window, copied into Tern's own folder when added.
public struct OutgoingAttachment: Codable, Sendable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "outgoingAttachment"

    public var id: Int64?
    public var localDraftID: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Relative to the `Outgoing` folder.
    public var path: String

    public init(localDraftID: String, filename: String, mimeType: String, size: Int, path: String) {
        self.localDraftID = localDraftID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.path = path
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One Gmail draft and the message that currently holds its content.
public struct DraftRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "draft"

    public var accountID: String
    public var id: String
    public var messageID: String
    public var threadID: String

    public init(accountID: String, id: String, messageID: String, threadID: String) {
        self.accountID = accountID
        self.id = id
        self.messageID = messageID
        self.threadID = threadID
    }
}

/// An attachment on a received message, listed when its body is stored.
public struct AttachmentRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachment"

    public var accountID: String
    public var messageID: String
    /// Stable across fetches, unlike `attachmentID`.
    public var partID: String
    /// Nil when Gmail returned the bytes inside the message.
    public var attachmentID: String?
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var isInline: Bool

    public var id: String { partID }

    public init(
        accountID: String, messageID: String, partID: String, attachmentID: String?,
        filename: String, mimeType: String, size: Int, isInline: Bool
    ) {
        self.accountID = accountID
        self.messageID = messageID
        self.partID = partID
        self.attachmentID = attachmentID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.isInline = isInline
    }
}

extension CacheTransaction {
    // MARK: Local drafts

    public func insertLocalDraft(_ draft: LocalDraft) throws {
        try draft.insert(db)
    }

    public func localDraft(id: String) throws -> LocalDraft? {
        try LocalDraft.fetchOne(db, key: id)
    }

    public func localDraft(gmailDraftID: String, accountID: String) throws -> LocalDraft? {
        try LocalDraft
            .filter(Column("accountID") == accountID && Column("gmailDraftID") == gmailDraftID)
            .fetchOne(db)
    }

    public func localDrafts(accountID: String) throws -> [LocalDraft] {
        try LocalDraft.filter(Column("accountID") == accountID).order(Column("createdAt"), Column("id")).fetchAll(db)
    }

    /// Stores an edit and raises the revision. Returns nil when the draft is
    /// gone or a queued send or discard has taken its content.
    @discardableResult
    public func updateLocalDraft(id: String, content: DraftContent, now: Date) throws -> LocalDraft? {
        guard var draft = try localDraft(id: id), draft.state == .editing else { return nil }
        guard draft.content != content else { return draft }
        draft.content = content
        try raiseRevision(of: &draft, now: now)
        return draft
    }

    /// Deletes a local draft and its attachment rows. Returns the attachments,
    /// whose files the caller removes.
    @discardableResult
    public func deleteLocalDraft(id: String) throws -> [OutgoingAttachment] {
        let attachments = try outgoingAttachments(localDraftID: id)
        _ = try LocalDraft.deleteOne(db, key: id)
        return attachments
    }

    private func raiseRevision(of draft: inout LocalDraft, now: Date) throws {
        draft.revision += 1
        draft.updatedAt = now
        try draft.update(db)
    }

    // MARK: Outgoing attachments

    public func outgoingAttachments(localDraftID: String) throws -> [OutgoingAttachment] {
        try OutgoingAttachment.filter(Column("localDraftID") == localDraftID).order(Column("id")).fetchAll(db)
    }

    /// Adds an attachment whose file is already in place and raises the
    /// draft's revision. Returns nil when the draft can't take edits.
    public func addOutgoingAttachment(_ attachment: OutgoingAttachment, now: Date) throws -> OutgoingAttachment? {
        guard var draft = try localDraft(id: attachment.localDraftID), draft.state == .editing else { return nil }
        var row = attachment
        try row.insert(db)
        try raiseRevision(of: &draft, now: now)
        return row
    }

    /// Removes an attachment row and raises the draft's revision. Returns the
    /// row, whose file the caller removes, or nil when nothing changed.
    public func removeOutgoingAttachment(id: Int64, now: Date) throws -> OutgoingAttachment? {
        guard let row = try OutgoingAttachment.fetchOne(db, key: id),
              var draft = try localDraft(id: row.localDraftID), draft.state == .editing
        else { return nil }
        _ = try row.delete(db)
        try raiseRevision(of: &draft, now: now)
        return row
    }

    // MARK: Gmail drafts

    public func draft(id: String, accountID: String) throws -> DraftRecord? {
        try DraftRecord.fetchOne(db, key: ["accountID": accountID, "id": id])
    }

    public func draft(messageID: String, accountID: String) throws -> DraftRecord? {
        try DraftRecord.filter(Column("accountID") == accountID && Column("messageID") == messageID).fetchOne(db)
    }

    /// Replaces the account's drafts with a `drafts.list` result. Drafts a local
    /// draft has saved stay, since a save can finish after the listing was taken.
    public func replaceDrafts(_ drafts: [DraftRecord], accountID: String) throws {
        for draft in drafts {
            try draft.upsert(db)
        }
        let saved = try localDrafts(accountID: accountID).compactMap(\.gmailDraftID)
        let kept = Array(Set(drafts.map(\.id)).union(saved))
        try DraftRecord.filter(Column("accountID") == accountID && !kept.contains(Column("id"))).deleteAll(db)
    }

    public func deleteDraft(id: String, accountID: String) throws {
        _ = try DraftRecord.deleteOne(db, key: ["accountID": accountID, "id": id])
    }

    /// Records a save Gmail accepted. The draft's new message replaces the one
    /// it held before, so a thread never shows two copies of a draft. `message`
    /// is the new message's metadata, when it could be fetched. Returns the
    /// replaced message IDs, which the caller keeps slow loads from restoring.
    @discardableResult
    public func recordDraftSave(
        _ draft: DraftRecord,
        localDraftID: String,
        revision: Int,
        message: MessageUpdate?
    ) throws -> Set<String> {
        var replaced = Set<String>()
        if let previous = try self.draft(id: draft.id, accountID: draft.accountID) { replaced.insert(previous.messageID) }
        let local = try localDraft(id: localDraftID)
        if let saved = local?.savedMessageID { replaced.insert(saved) }
        replaced.remove(draft.messageID)

        try draft.upsert(db)
        if var row = local {
            row.gmailDraftID = draft.id
            row.savedMessageID = draft.messageID
            row.threadID = draft.threadID
            row.savedRevision = max(row.savedRevision, revision)
            try row.update(db)
        }
        var threads = try deleteMessages(ids: replaced, accountID: draft.accountID)
        if let message { threads.formUnion(try upsertMessages([message])) }
        try rebuildThreads(threads, accountID: draft.accountID)
        return replaced
    }

    // MARK: Received attachments

    public func attachments(messageID: String, accountID: String) throws -> [AttachmentRecord] {
        try AttachmentRecord
            .filter(Column("accountID") == accountID && Column("messageID") == messageID)
            .order(Column.rowID) // payload order, as stored
            .fetchAll(db)
    }

    /// Replaces the attachments listed for one message.
    public func replaceAttachments(_ attachments: [AttachmentRecord], messageID: String, accountID: String) throws {
        try AttachmentRecord.filter(Column("accountID") == accountID && Column("messageID") == messageID).deleteAll(db)
        for attachment in attachments {
            try attachment.insert(db)
        }
    }
}
