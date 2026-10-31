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
    /// The address the message goes out from. Nil for the account's own address.
    public var fromAddress: String?
    /// The From address's signature as inserted, kept if the identity changes later.
    public var signatureHTML: String?
    public var composeFont: ComposeFont
    public var signatureAboveQuote: Bool
    public var signatureSeparator: Bool
    public var archiveAfterSend: Bool

    public init(
        to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
        subject: String = "", body: ComposeDocument = ComposeDocument(),
        fromAddress: String? = nil, signatureHTML: String? = nil, composeFont: ComposeFont = .sansSerif,
        signatureAboveQuote: Bool = true, signatureSeparator: Bool = false, archiveAfterSend: Bool = false
    ) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.fromAddress = fromAddress
        self.signatureHTML = signatureHTML
        self.composeFont = composeFont
        self.signatureAboveQuote = signatureAboveQuote
        self.signatureSeparator = signatureSeparator
        self.archiveAfterSend = archiveAfterSend
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
        /// An answer to an invitation, sent without a compose window.
        case invitationReply
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
    public var fromAddress: String?
    public var signatureHTML: String?
    public var composeFont: ComposeFont
    public var signatureAboveQuote: Bool
    public var signatureSeparator: Bool
    public var archiveAfterSend: Bool
    /// For an invitation reply, the `text/calendar` REPLY it sends.
    public var calendarPart: String?
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
    /// Set just before an upload and cleared when a save is recorded. While
    /// set, Gmail may hold an upload whose answer was lost: a message in the
    /// Gmail draft that `savedMessageID` doesn't name, or a whole draft whose
    /// ID never came back. Either carries `rfcMessageID`.
    public var hasUnrecordedUpload: Bool
    /// Set just before Tern first asks Gmail to send the draft. `drafts.send`
    /// consumes its draft, so a draft gone after that was sent.
    public var sendRequested: Bool
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, accountID, gmailDraftID, savedMessageID, threadID, kind, sourceMessageID
        case to = "toAddresses", cc = "ccAddresses", bcc = "bccAddresses"
        case subject, body, fromAddress, signatureHTML, calendarPart, quotedHTML, quotedPlainText, rfcMessageID, inReplyTo
        case composeFont, signatureAboveQuote, signatureSeparator, archiveAfterSend
        case references = "referencesHeader"
        case revision, savedRevision, state, sendError, hasUnrecordedUpload, sendRequested, createdAt, updatedAt
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
        calendarPart: String? = nil,
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
        fromAddress = content.fromAddress
        signatureHTML = content.signatureHTML
        composeFont = content.composeFont
        signatureAboveQuote = content.signatureAboveQuote
        signatureSeparator = content.signatureSeparator
        archiveAfterSend = content.archiveAfterSend
        self.calendarPart = calendarPart
        self.quotedHTML = quotedHTML
        self.quotedPlainText = quotedPlainText
        self.rfcMessageID = rfcMessageID
        self.inReplyTo = inReplyTo
        self.references = references
        revision = 0
        savedRevision = 0
        state = .editing
        sendError = nil
        hasUnrecordedUpload = false
        sendRequested = false
        createdAt = now
        updatedAt = now
    }

    public var content: DraftContent {
        get {
            DraftContent(
                to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                fromAddress: fromAddress, signatureHTML: signatureHTML, composeFont: composeFont,
                signatureAboveQuote: signatureAboveQuote, signatureSeparator: signatureSeparator, archiveAfterSend: archiveAfterSend
            )
        }
        set {
            to = newValue.to
            cc = newValue.cc
            bcc = newValue.bcc
            subject = newValue.subject
            body = newValue.body
            fromAddress = newValue.fromAddress
            signatureHTML = newValue.signatureHTML
            composeFont = newValue.composeFont
            signatureAboveQuote = newValue.signatureAboveQuote
            signatureSeparator = newValue.signatureSeparator
            archiveAfterSend = newValue.archiveAfterSend
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
    /// Nil for ordinary attachments; stable across saves/retries for inline images.
    public var contentID: String?

    public init(localDraftID: String, filename: String, mimeType: String, size: Int, path: String, contentID: String? = nil) {
        self.localDraftID = localDraftID
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.path = path
        self.contentID = contentID
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
public struct AttachmentRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
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

    /// Notes that an upload of the draft is about to go out, or with
    /// `sending`, a send. Called before the request, since its answer can be lost.
    public func markUploadStarted(localDraftID: String, sending: Bool = false) throws {
        guard var draft = try localDraft(id: localDraftID) else { return }
        draft.hasUnrecordedUpload = true
        draft.sendRequested = draft.sendRequested || sending
        try draft.update(db)
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
            row.hasUnrecordedUpload = false
            try row.update(db)
        }
        var threads = try deleteMessages(ids: replaced, accountID: draft.accountID)
        if let message { threads.formUnion(try upsertMessages([message])) }
        try rebuildThreads(threads, accountID: draft.accountID)
        return replaced
    }

    // MARK: Queue rows

    /// The queue rows for one local draft, oldest first.
    public func composeRows(localDraftID: String) throws -> [PendingAction] {
        try PendingAction.filter(Column("localDraftID") == localDraftID && Column("state") != PendingAction.State.failed.rawValue)
            .order(Column("id")).fetchAll(db)
    }

    /// Queues a save, first storing `content` when given. Returns nil when a
    /// queued save will upload the newest revision anyway, or when the draft
    /// can't be saved.
    @discardableResult
    public func enqueueSave(localDraftID: String, content: DraftContent? = nil, now: Date, notBefore: Date) throws -> PendingAction? {
        if let content { try updateLocalDraft(id: localDraftID, content: content, now: now) }
        guard let draft = try localDraft(id: localDraftID), draft.state == .editing else { return nil }
        let waiting = try composeRows(localDraftID: localDraftID).contains { $0.kind == .saveDraft && $0.state == .queued }
        guard !waiting else { return nil }
        return try insertComposeRow(.saveDraft, for: draft, now: now, notBefore: notBefore)
    }

    /// Queues a send for `notBefore`, the end of the undo send delay, first
    /// storing `content` when given. The draft stops taking edits, waiting
    /// saves go since the send uploads the newest revision, and the draft's
    /// message leaves its thread. A provisional message from `rendering`
    /// takes its place there and in Sent until Gmail's copy arrives (`LocalSend`).
    public func enqueueSend(
        localDraftID: String, content: DraftContent? = nil, now: Date, notBefore: Date,
        rendering: (LocalDraft) -> LocalSend.Rendering
    ) throws -> PendingAction? {
        try enqueueExit(.sendDraft, state: .sending, localDraftID: localDraftID, content: content, now: now, notBefore: notBefore) {
            try insertLocalSend(for: $0, rendering: rendering($0), now: now)
        }
    }

    /// Queues a discard for `notBefore`, while its notice offers undo.
    public func enqueueDiscard(localDraftID: String, content: DraftContent? = nil, now: Date, notBefore: Date) throws -> PendingAction? {
        try enqueueExit(.discardDraft, state: .discarding, localDraftID: localDraftID, content: content, now: now, notBefore: notBefore)
    }

    /// `standIn` stores what shows in place of the draft's message while it
    /// leaves, if anything, and returns the thread that holds it.
    private func enqueueExit(
        _ kind: PendingAction.Kind, state: LocalDraft.State, localDraftID: String,
        content: DraftContent?, now: Date, notBefore: Date,
        standIn: (LocalDraft) throws -> String? = { _ in nil }
    ) throws -> PendingAction? {
        if let content { try updateLocalDraft(id: localDraftID, content: content, now: now) }
        guard var draft = try localDraft(id: localDraftID), draft.state == .editing else { return nil }
        try PendingAction
            .filter(Column("localDraftID") == localDraftID && Column("kind") == PendingAction.Kind.saveDraft.rawValue)
            .filter(Column("state") == PendingAction.State.queued.rawValue)
            .deleteAll(db)
        draft.state = state
        draft.sendError = nil
        try draft.update(db)
        let row = try insertComposeRow(kind, for: draft, now: now, notBefore: notBefore)
        var threads = try threadIDs(of: draft)
        if let thread = try standIn(draft) { threads.insert(thread) }
        try rebuildThreads(threads, accountID: draft.accountID)
        return row
    }

    /// Undoes a send or discard whose request hasn't started, and returns the
    /// draft to editing. Returns false once Gmail may have seen it.
    public func cancelExit(localDraftID: String) throws -> Bool {
        guard let draft = try localDraft(id: localDraftID), draft.state != .editing else { return false }
        let kind: PendingAction.Kind = draft.state == .sending ? .sendDraft : .discardDraft
        guard let row = try composeRows(localDraftID: localDraftID).first(where: { $0.kind == kind }),
              row.state == .queued, row.attempts == 0
        else { return false }
        _ = try row.delete(db)
        try returnToEditing(localDraftID: localDraftID)
        if kind == .sendDraft {
            try db.execute(sql: "UPDATE localDraft SET archiveAfterSend = 0 WHERE id = ?", arguments: [localDraftID])
        }
        return true
    }

    /// Returns a draft whose send or discard didn't happen to editing, so its
    /// message shows in its thread again in place of its provisional send.
    /// `sendError` is Gmail's reason, if any. `forgettingGmailDraft` drops a
    /// Gmail draft that no longer exists, so the next save creates one.
    public func returnToEditing(localDraftID: String, sendError: String? = nil, forgettingGmailDraft: Bool = false) throws {
        guard var draft = try localDraft(id: localDraftID) else { return }
        var threads = try threadIDs(of: draft)
        threads.formUnion(try deleteLocalSend(localDraftID: localDraftID, accountID: draft.accountID))
        draft.state = .editing
        draft.sendError = sendError
        // The send didn't happen, so a later one that finds the draft gone
        // doesn't count as sent.
        draft.sendRequested = false
        if forgettingGmailDraft {
            if let id = draft.gmailDraftID { try deleteDraft(id: id, accountID: draft.accountID) }
            draft.gmailDraftID = nil
            draft.savedMessageID = nil
            draft.savedRevision = 0
        }
        try draft.update(db)
        try rebuildThreads(threads, accountID: draft.accountID)
    }

    /// Removes a draft that has left Gmail, by sending or discarding: the local
    /// draft and its rows, its Gmail draft, its message and its provisional
    /// send. `sentMessage` is the sent message's metadata, when it could be
    /// fetched, and takes the provisional message's place in this same write.
    /// Returns the outgoing attachments, whose files the caller removes, and
    /// the removed message IDs, which the caller keeps slow loads from restoring.
    public func removeFinishedDraft(
        localDraftID: String,
        sentMessage: MessageUpdate?
    ) throws -> (attachments: [OutgoingAttachment], removedMessageIDs: Set<String>) {
        guard let draft = try localDraft(id: localDraftID) else { return ([], []) }
        var removed = Set([draft.savedMessageID].compactMap { $0 })
        if let id = draft.gmailDraftID {
            if let record = try self.draft(id: id, accountID: draft.accountID) { removed.insert(record.messageID) }
            try deleteDraft(id: id, accountID: draft.accountID)
        }
        if let sent = sentMessage?.record.id { removed.remove(sent) }
        try PendingAction.filter(Column("localDraftID") == localDraftID).deleteAll(db)
        let attachments = try deleteLocalDraft(id: localDraftID)
        var threads = try deleteMessages(ids: removed, accountID: draft.accountID)
        threads.formUnion(try deleteLocalSend(localDraftID: localDraftID, accountID: draft.accountID))
        if let sentMessage { threads.formUnion(try upsertMessages([sentMessage])) }
        try rebuildThreads(threads, accountID: draft.accountID)
        return (attachments, removed)
    }

    /// Draft messages that a queued send or discard is about to remove.
    /// Threads leave them out, so the draft shows only in the Outbox.
    func hiddenDraftMessageIDs(accountID: String) throws -> Set<String> {
        try String.fetchSet(db, sql: """
            SELECT message.id
            FROM localDraft
            LEFT JOIN draft ON draft.accountID = localDraft.accountID AND draft.id = localDraft.gmailDraftID
            JOIN message ON message.accountID = localDraft.accountID
                AND (message.id = localDraft.savedMessageID OR message.id = draft.messageID)
            JOIN messageLabel ON messageLabel.accountID = message.accountID
                AND messageLabel.messageID = message.id AND messageLabel.labelID = ?
            WHERE localDraft.accountID = ? AND localDraft.state != ?
            """, arguments: [SystemLabel.draft, accountID, LocalDraft.State.editing.rawValue])
    }

    /// The threads that hold a local draft's Gmail messages.
    private func threadIDs(of draft: LocalDraft) throws -> Set<String> {
        var messageIDs = [draft.savedMessageID].compactMap { $0 }
        if let id = draft.gmailDraftID, let record = try self.draft(id: id, accountID: draft.accountID) {
            messageIDs.append(record.messageID)
        }
        return try threadIDsOf(messageIDs: messageIDs, accountID: draft.accountID)
    }

    private func insertComposeRow(_ kind: PendingAction.Kind, for draft: LocalDraft, now: Date, notBefore: Date) throws -> PendingAction {
        var row = PendingAction(
            id: nil, accountID: draft.accountID, kind: kind,
            threadIDs: [], messageIDs: [], addLabelIDs: [], removeLabelIDs: [], diff: [:],
            state: .queued, attempts: 0, lastError: nil,
            createdAt: now, notBefore: notBefore, sentAt: nil, localDraftID: draft.id
        )
        try row.insert(db)
        return row
    }

    // MARK: Received attachments

    public func attachments(messageID: String, accountID: String) throws -> [AttachmentRecord] {
        try AttachmentRecord
            .filter(Column("accountID") == accountID && Column("messageID") == messageID)
            .order(Column.rowID) // payload order, as stored
            .fetchAll(db)
    }

    /// Replaces the attachments listed for one message.
    /// Stores a message's attachment parts, writing only the rows that differ.
    /// A thread fetch brings the same parts again, with new attachment IDs at
    /// most, so this keeps the reader's observers quiet.
    public func replaceAttachments(_ attachments: [AttachmentRecord], messageID: String, accountID: String) throws {
        let stored = Dictionary(
            try AttachmentRecord.filter(Column("accountID") == accountID && Column("messageID") == messageID).fetchAll(db)
                .map { ($0.partID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var kept = Set<String>()
        for attachment in attachments {
            kept.insert(attachment.partID)
            if let old = stored[attachment.partID] {
                if !attachment.databaseEquals(old) { try attachment.update(db) }
            } else {
                try attachment.upsert(db)
            }
        }
        for (partID, old) in stored where !kept.contains(partID) {
            try old.delete(db)
        }
    }
}
