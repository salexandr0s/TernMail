import Foundation
import GmailAPI
import MailStore
import MessageContent

/// Why a draft can't be uploaded at all. Shown to the user as is.
enum ComposeError: Error, Equatable, LocalizedError {
    case missingAttachment(String)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .missingAttachment(let name):
            "Tern can't find the attachment “\(name)”. Remove it and attach it again."
        case .tooLarge:
            "This message is larger than Gmail accepts. Remove some attachments and try again."
        }
    }
}

extension SyncEngine {
    /// Gmail's limit for a message uploaded through the API.
    static let maxMessageSize = 35_000_000
    /// Above this size, saves wait `largeSaveInterval` apart.
    static let largeMessageSize = 1_000_000
    static let largeSaveInterval: TimeInterval = 30

    // MARK: Compose window

    public func createDraft(_ draft: LocalDraft) async throws {
        try await write { tx in try tx.insertLocalDraft(draft) }
    }

    /// Stores an edit locally. Returns the draft with its new revision, or nil
    /// when a queued send or discard has taken it.
    @discardableResult
    public func updateDraft(_ localDraftID: String, content: DraftContent) async throws -> LocalDraft? {
        let now = now()
        return try await write { tx in try tx.updateLocalDraft(id: localDraftID, content: content, now: now) }
    }

    /// Queues an upload of the draft's newest revision, first storing `content` when given.
    public func saveDraft(_ localDraftID: String, content: DraftContent? = nil) async throws {
        let now = now()
        let notBefore = max(now, nextLargeSave[localDraftID] ?? now)
        _ = try await write { tx in try tx.enqueueSave(localDraftID: localDraftID, content: content, now: now, notBefore: notBefore) }
        scheduleSending()
    }

    /// Queues the send for after `delay`, the undo send delay, first storing
    /// `content` when given. Returns false when the draft can't be sent.
    @discardableResult
    public func sendDraft(_ localDraftID: String, content: DraftContent? = nil, delay: TimeInterval) async throws -> Bool {
        let now = now()
        let row = try await write { tx in
            try tx.enqueueSend(localDraftID: localDraftID, content: content, now: now, notBefore: now.addingTimeInterval(delay))
        }
        scheduleSending()
        return row != nil
    }

    /// Cancels a send that hasn't started. Returns false once it has.
    public func undoSend(_ localDraftID: String) async throws -> Bool {
        try await write { tx in try tx.cancelExit(localDraftID: localDraftID) }
    }

    /// Queues the discard for after `hold`, while its notice offers undo.
    @discardableResult
    public func discardDraft(_ localDraftID: String, content: DraftContent? = nil, hold: TimeInterval) async throws -> Bool {
        let now = now()
        let row = try await write { tx in
            try tx.enqueueDiscard(localDraftID: localDraftID, content: content, now: now, notBefore: now.addingTimeInterval(hold))
        }
        scheduleSending()
        return row != nil
    }

    /// Cancels a discard that hasn't started. Returns false once it has.
    public func undoDiscard(_ localDraftID: String) async throws -> Bool {
        try await write { tx in try tx.cancelExit(localDraftID: localDraftID) }
    }

    /// Adds a file already copied under `outgoingDirectory`. Returns nil when
    /// the draft no longer takes edits.
    public func addAttachment(_ attachment: OutgoingAttachment) async throws -> OutgoingAttachment? {
        let now = now()
        return try await write { tx in try tx.addOutgoingAttachment(attachment, now: now) }
    }

    /// Removes an attachment and its file.
    public func removeAttachment(id: Int64) async throws {
        let now = now()
        let removed = try await write { tx in try tx.removeOutgoingAttachment(id: id, now: now) }
        if let removed { try? FileManager.default.removeItem(at: outgoingDirectory.appending(path: removed.path)) }
    }

    /// Sends every waiting send at once, as when quitting, and returns true
    /// once all of them went. Returns false if one fails or can't reach Gmail.
    public func sendWaitingDraftsNow() async -> Bool {
        let accountID = accountID
        let now = now()
        do {
            try await write { tx in
                for var row in try tx.pendingActions(accountID: accountID) where row.kind == .sendDraft && row.state == .queued {
                    row.notBefore = min(row.notBefore, now)
                    try tx.updateAction(row)
                }
            }
        } catch {
            return false
        }
        while !Task.isCancelled, !isStopped {
            await sendDueDrafts()
            let rows = try? await cache.read { tx in
                try tx.pendingActions(accountID: accountID).filter { $0.kind == .sendDraft }
            }
            guard let rows else { return false }
            if rows.isEmpty { return true }
            if rows.contains(where: { $0.state == .queued && $0.lastError != nil }) { return false }
            // Another sender has the row; wait for it.
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: Sending

    /// Uploads every due draft row, one at a time, and returns how many it claimed.
    @discardableResult
    public func sendDueDrafts() async -> Int {
        let accountID = accountID
        let now = now()
        guard let due = try? await write({ tx in try tx.claimDueActions(accountID: accountID, now: now, lane: .compose) }) else {
            return 0
        }
        for row in due {
            // Unstarted rows stay claimed and are requeued at the next start.
            guard !isStoppingDrafts, !isStopped, !Task.isCancelled else { break }
            await run(row)
        }
        return due.count
    }

    private func run(_ row: PendingAction) async {
        guard let localDraftID = row.localDraftID else { return }
        draftRowInFlight = row.kind
        defer { draftRowInFlight = nil }
        do {
            switch row.kind {
            case .saveDraft: try await upload(row, localDraftID: localDraftID)
            case .sendDraft: try await deliver(row, localDraftID: localDraftID)
            case .discardDraft: try await discard(row, localDraftID: localDraftID)
            case .modifyThreads, .modifyMessages, .trashThreads, .untrashThreads: return
            }
        } catch {
            await finish(row, localDraftID: localDraftID, after: error)
        }
    }

    private func upload(_ row: PendingAction, localDraftID: String) async throws {
        guard let prepared = try await prepare(localDraftID) else { return try await drop(row) }
        _ = try await save(prepared, attempts: row.attempts)
        let now = now()
        let notBefore = max(now, nextLargeSave[localDraftID] ?? now)
        try await write { tx in
            if let id = row.id { try tx.deleteAction(id: id) }
            // Edits made during the upload go out in another save.
            if let current = try tx.localDraft(id: localDraftID), current.revision > prepared.draft.revision {
                try tx.enqueueSave(localDraftID: localDraftID, now: now, notBefore: notBefore)
            }
        }
        scheduleSending()
    }

    private func deliver(_ row: PendingAction, localDraftID: String) async throws {
        guard let prepared = try await prepare(localDraftID) else { return try await drop(row) }
        // A draft that never reached Gmail is saved first, so a retry finds
        // it instead of creating another.
        var draftID = prepared.draft.gmailDraftID
        if draftID == nil { draftID = try await save(prepared, attempts: row.attempts).id }
        guard let draftID else { return }
        let sent: GmailMessage
        do {
            sent = try await gmail.sendDraft(id: draftID, with: prepared.message)
        } catch GmailError.notFound where row.attempts > 1 {
            // drafts.send consumes its draft, so an earlier attempt went out.
            return try await finishRemoving(localDraftID, sentMessageID: nil, sent: true)
        } catch GmailError.notFound {
            throw DraftGone()
        }
        try await finishRemoving(localDraftID, sentMessageID: sent.id, sent: true)
    }

    private func discard(_ row: PendingAction, localDraftID: String) async throws {
        let accountID = accountID
        let draft = try await cache.read { tx in try tx.localDraft(id: localDraftID) }
        guard let draft, draft.accountID == accountID else { return try await drop(row) }
        if let id = draft.gmailDraftID {
            do {
                try await gmail.deleteDraft(id: id)
            } catch GmailError.notFound {
                // Already gone, which is what the discard wanted.
            }
        }
        try await finishRemoving(localDraftID, sentMessageID: nil, sent: false)
    }

    private struct Prepared {
        let draft: LocalDraft
        let message: OutgoingMessage
    }

    private struct DraftGone: Error {}

    /// The local draft and its encoded message, or nil when the draft is gone.
    private func prepare(_ localDraftID: String) async throws -> Prepared? {
        let stored = try await cache.read { tx -> (LocalDraft, [OutgoingAttachment])? in
            guard let draft = try tx.localDraft(id: localDraftID) else { return nil }
            return (draft, try tx.outgoingAttachments(localDraftID: localDraftID))
        }
        guard let (draft, attachments) = stored else { return nil }
        var files: [MIMEMessage.Attachment] = []
        for attachment in attachments {
            guard let data = try? Data(contentsOf: outgoingDirectory.appending(path: attachment.path)) else {
                throw ComposeError.missingAttachment(attachment.filename)
            }
            files.append(MIMEMessage.Attachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data))
        }
        let raw = Self.message(for: draft, attachments: files, sender: sender, date: now()).encoded()
        guard raw.count <= Self.maxMessageSize else { throw ComposeError.tooLarge }
        if raw.count > Self.largeMessageSize {
            nextLargeSave[localDraftID] = now().addingTimeInterval(Self.largeSaveInterval)
        }
        return Prepared(draft: draft, message: OutgoingMessage(raw: raw, threadID: draft.threadID))
    }

    /// Creates or updates the Gmail draft and records it, replacing the
    /// draft's earlier message in the cache.
    private func save(_ prepared: Prepared, attempts: Int) async throws -> DraftRecord {
        var draftID = prepared.draft.gmailDraftID
        if draftID == nil, attempts > 1 {
            draftID = try await findUnrecordedDraft(prepared.draft)
        }
        let saved: GmailDraft
        if let draftID {
            do {
                saved = try await gmail.updateDraft(id: draftID, with: prepared.message)
            } catch GmailError.notFound {
                // Deleted in another app while open here. Keep the text as a new draft.
                saved = try await gmail.createDraft(prepared.message)
            }
        } else {
            saved = try await gmail.createDraft(prepared.message)
        }
        guard let message = saved.message, !message.id.isEmpty else { throw GmailError.decoding("Draft message") }
        let record = DraftRecord(accountID: accountID, id: saved.id, messageID: message.id, threadID: message.threadId)
        // The save response has no history ID, so the metadata is fetched.
        // Without it, the next sync brings the message.
        let metadata = try? await fetchMetadata([message.id]).updates.first
        let deleted = deletedMessageIDs
        let revision = prepared.draft.revision
        try await write { tx in
            let replaced = try tx.recordDraftSave(record, localDraftID: prepared.draft.id, revision: revision, message: metadata)
            deleted.withLock { $0.formUnion(replaced) }
        }
        return record
    }

    /// After an attempt whose answer was lost, the draft may exist without
    /// our knowing its ID. It carries our Message-ID, so search for it
    /// rather than create a second one.
    private func findUnrecordedDraft(_ draft: LocalDraft) async throws -> String? {
        let messageID = draft.rfcMessageID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let page = try await gmail.drafts(query: "rfc822msgid:\(messageID)", pageToken: nil, maxResults: 10)
        let accountID = accountID
        for candidate in page.drafts ?? [] {
            let owner = try await cache.read { tx in try tx.localDraft(gmailDraftID: candidate.id, accountID: accountID) }
            if owner == nil || owner?.id == draft.id { return candidate.id }
        }
        return nil
    }

    /// Removes a sent or discarded draft locally, with its files.
    private func finishRemoving(_ localDraftID: String, sentMessageID: String?, sent: Bool) async throws {
        let sentMessage = if let sentMessageID { try? await fetchMetadata([sentMessageID]).updates.first } else { nil as CacheTransaction.MessageUpdate? }
        let deleted = deletedMessageIDs
        try await write { tx in
            let removed = try tx.removeFinishedDraft(localDraftID: localDraftID, sentMessage: sentMessage)
            deleted.withLock { $0.formUnion(removed.removedMessageIDs) }
        }
        nextLargeSave[localDraftID] = nil
        try? FileManager.default.removeItem(at: outgoingDirectory.appending(path: localDraftID, directoryHint: .isDirectory))
        if sent { continuation.yield(.draftSent(localDraftID: localDraftID)) }
    }

    /// Drops a row whose draft no longer exists.
    private func drop(_ row: PendingAction) async throws {
        guard let id = row.id else { return }
        try await write { tx in try tx.deleteAction(id: id) }
    }

    /// Retries what may still work, and returns the draft to editing with a
    /// message for anything Gmail refused.
    private func finish(_ row: PendingAction, localDraftID: String, after error: any Error) async {
        guard let id = row.id, !(error is CancellationError) else { return }
        let now = now()
        if Self.shouldRetryDraft(error) {
            var retry = row
            retry.state = .queued
            // Error descriptions carry no message content or addresses.
            retry.lastError = error is GmailError ? String(describing: error) : String(describing: type(of: error))
            retry.notBefore = now.addingTimeInterval(min(pow(2, Double(row.attempts)), 300))
            _ = try? await write { [retry] tx in
                if try tx.action(id: id) != nil { try tx.updateAction(retry) }
            }
            return
        }
        let message = Self.failureMessage(for: error, kind: row.kind)
        let forget = error is DraftGone
        do {
            try await write { tx in
                try tx.deleteAction(id: id)
                try tx.returnToEditing(localDraftID: localDraftID, sendError: message, forgettingGmailDraft: forget)
            }
            continuation.yield(.draftFailed(localDraftID: localDraftID, message: message))
        } catch {
            // The row stays claimed and is retried at the next start.
        }
    }

    private static func shouldRetryDraft(_ error: any Error) -> Bool {
        switch error {
        case is ComposeError, is DraftGone:
            false
        case let error as GmailError:
            // A retry finds a draft created by a lost response through its
            // Message-ID, and a lost send by its 404.
            shouldRetry(error)
        default:
            true
        }
    }

    private static func failureMessage(for error: any Error, kind: PendingAction.Kind) -> String {
        if let error = error as? ComposeError { return error.errorDescription ?? "" }
        if error is DraftGone { return "This draft was sent or deleted in another app." }
        switch kind {
        case .sendDraft: return "Gmail didn't send this message. Check the recipients and try again."
        case .discardDraft: return "Tern couldn't discard this draft."
        default: return "Gmail didn't save this draft. Check the recipients and try again."
        }
    }

    /// The draft as an RFC 5322 message: the new text, then the quote.
    static func message(for draft: LocalDraft, attachments: [MIMEMessage.Attachment], sender: EmailAddress, date: Date) -> MIMEMessage {
        var message = MIMEMessage(from: sender)
        message.to = draft.to
        message.cc = draft.cc
        message.bcc = draft.bcc
        message.subject = draft.subject
        message.date = date
        message.messageID = draft.rfcMessageID
        message.inReplyTo = draft.inReplyTo
        message.references = draft.references
        message.html = draft.body.html() + (draft.quotedHTML ?? "")
        let text = draft.body.plainText()
        message.plainText = draft.quotedPlainText.map { text + "\n\n" + $0 } ?? text
        message.attachments = attachments
        return message
    }
}
