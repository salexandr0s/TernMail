import Foundation
import GmailAPI
import MailStore
import MessageContent

/// A draft ready for its compose window.
public struct OpenedDraft: Sendable, Equatable {
    public var draft: LocalDraft
    /// The draft's HTML had formatting the editor can't keep, such as tables
    /// or fonts, so the window warns before the first edit.
    public var droppedFormatting: Bool
}

extension SyncEngine {
    // MARK: New messages, replies and forwards

    public func startMessage() async throws -> LocalDraft {
        let draft = LocalDraft(accountID: accountID, kind: .new, rfcMessageID: MIMEMessage.newMessageID(for: sender), now: now())
        try await createDraft(draft)
        return draft
    }

    /// Starts a reply or forward. A reply builds on the cached message when
    /// its headers and body are there. Otherwise, and for every forward, the
    /// message comes from Gmail, and a forward copies the original's files.
    public func startReply(_ kind: ReplyKind, to messageID: String) async throws -> LocalDraft {
        let accountID = accountID
        var original = try await cache.read { tx -> OriginalMessage? in
            guard kind != .forward,
                  let record = try tx.message(id: messageID, accountID: accountID), record.rfcMessageID != nil,
                  let body = try tx.body(messageID: messageID, accountID: accountID)
            else { return nil }
            return OriginalMessage(record, body: body)
        }
        var files: [AttachmentPart] = []
        var message: GmailMessage?
        if original == nil {
            let fetched = try await fullMessage(messageID)
            original = fetched.original
            message = fetched.message
            if kind == .forward { files = MIMEParts.attachments(of: fetched.message).filter { !$0.isInline } }
        }
        guard let original else { throw GmailError.decoding("Original message") }
        let reply = ReplyBuilder.draft(kind, replyingTo: original, ownAddresses: [sender.address])
        let draft = LocalDraft(
            accountID: accountID,
            kind: LocalDraft.Kind(kind),
            content: DraftContent(to: reply.to, cc: reply.cc, subject: reply.subject),
            rfcMessageID: MIMEMessage.newMessageID(for: sender),
            threadID: reply.threadID,
            sourceMessageID: messageID,
            inReplyTo: reply.inReplyTo,
            references: reply.references,
            quotedHTML: reply.quotedHTML,
            quotedPlainText: reply.quotedPlainText,
            now: now()
        )
        let copies = if let message { try await download(files, of: message, for: draft.id) } else { [OutgoingAttachment]() }
        let now = now()
        do {
            try await write { tx in
                try tx.insertLocalDraft(draft)
                for copy in copies { _ = try tx.addOutgoingAttachment(copy, now: now) }
            }
        } catch {
            removeFiles(copies)
            throw error
        }
        return try await cache.read { tx in try tx.localDraft(id: draft.id) } ?? draft
    }

    /// Moves a new message to `destination`'s account, as the From menu does.
    /// The copy gets its own ID, Message-ID and files, and holds `content`,
    /// the window's text. The original's discard is queued in the same
    /// transaction, so the message is never in both accounts. Returns nil
    /// when the draft isn't a new message or no longer takes edits, and
    /// throws `CancellationError` when `destination` is stopping or stopped.
    public func moveDraft(_ localDraftID: String, content: DraftContent, to destination: SyncEngine) async throws -> LocalDraft? {
        guard destination !== self else { return nil }
        // This engine writes the destination's rows, so its write gate alone
        // can't keep them out of an account that is being removed.
        let destinationStopped = destination.stopRequested
        if destinationStopped.withLock({ $0 }) { throw CancellationError() }
        let files = try await cache.read { tx in try tx.outgoingAttachments(localDraftID: localDraftID) }
        let moved = LocalDraft(
            accountID: destination.accountID, kind: .new, content: content,
            rfcMessageID: MIMEMessage.newMessageID(for: destination.sender), now: now()
        )
        // The copy's files are all in its own new folder, removed if the move fails.
        let folder = destination.outgoingDirectory.appending(path: moved.id, directoryHint: .isDirectory)
        let copies: [OutgoingAttachment]
        do {
            copies = try copyFiles(files, for: moved.id, into: destination.outgoingDirectory)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let now = now()
        let result: (draft: LocalDraft, saves: Bool)?
        do {
            result = try await write { tx -> (LocalDraft, Bool)? in
                // Checked again here, so nothing lands after the destination's data is deleted.
                if destinationStopped.withLock({ $0 }) { throw CancellationError() }
                // Read here, since a send or discard may have taken the draft during the copy.
                guard let original = try tx.localDraft(id: localDraftID), original.kind == .new, original.state == .editing
                else { return nil }
                _ = try tx.enqueueDiscard(localDraftID: localDraftID, now: now, notBefore: now)
                var draft = moved
                // Edits carry over, so closing the window keeps the copy as it would the original.
                draft.revision = original.revision + (content == original.content ? 0 : 1)
                try tx.insertLocalDraft(draft)
                for copy in copies { _ = try tx.addOutgoingAttachment(copy, now: now) }
                // Gmail held the original, so the copy goes there at once.
                let saves = original.gmailDraftID != nil
                if saves { _ = try tx.enqueueSave(localDraftID: draft.id, now: now, notBefore: now) }
                return (try tx.localDraft(id: draft.id) ?? draft, saves)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        guard let result else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        scheduleSending()
        if result.saves { await destination.scheduleSending() }
        return result.draft
    }

    /// A message in `full` format, with any text Gmail stores as an attachment.
    private func fullMessage(_ messageID: String) async throws -> (message: GmailMessage, original: OriginalMessage) {
        let results = try await gmail.messages(ids: [messageID], format: .full, metadataHeaders: [])
        let message: GmailMessage
        switch results[messageID] {
        case .success(let fetched)?: message = fetched
        case .failure(let error)?: throw error
        case nil: throw GmailError.missingBatchPart
        }
        var original = OriginalMessage(message)
        original.body = try await body(of: message)
        return (message, original)
    }

    private func body(of message: GmailMessage) async throws -> ExtractedBody {
        var textParts: [String: Data] = [:]
        for id in MIMEParts.requiredAttachmentIDs(of: message).sorted() {
            textParts[id] = try await gmail.attachment(messageID: message.id, attachmentID: id)
        }
        return MIMEParts.body(of: message, attachments: textParts)
    }

    // MARK: Gmail drafts

    /// Opens the Gmail draft holding `messageID`, as Edit Draft in a thread does.
    public func openDraft(messageID: String) async throws -> OpenedDraft {
        let accountID = accountID
        let lookup = { @Sendable (tx: CacheTransaction) in try tx.draft(messageID: messageID, accountID: accountID) }
        var record = try await cache.read(lookup)
        if record == nil {
            // Made in another app since the last full sync.
            try await refreshDrafts()
            record = try await cache.read(lookup)
        }
        guard let record else { throw ComposeError.draftGone }
        return try await openDraft(id: record.id)
    }

    /// Opens a Gmail draft. One already open here comes back as it is unless
    /// another app changed it since and no save of it is uploading: then
    /// Gmail's copy is imported, and local changes Gmail hasn't seen go on as
    /// a new draft.
    public func openDraft(id: String) async throws -> OpenedDraft {
        let accountID = accountID
        let lookup = { @Sendable (tx: CacheTransaction) in try tx.localDraft(gmailDraftID: id, accountID: accountID) }
        let existing = try await cache.read(lookup)
        if let existing, existing.state != .editing { return OpenedDraft(draft: existing, droppedFormatting: false) }
        let fetched: GmailDraft
        do {
            fetched = try await gmail.draft(id: id, format: .full)
        } catch GmailError.notFound {
            // Deleted in another app. A local copy is saved again as a new draft.
            if let existing { return OpenedDraft(draft: existing, droppedFormatting: false) }
            throw ComposeError.draftGone
        }
        guard let message = fetched.message, !message.id.isEmpty else { throw GmailError.decoding("Draft message") }
        // Read again, since a save may have started or finished during the
        // fetch. Gmail's message may be Tern's own upload, still in flight
        // or with its answer lost, rather than another app's change.
        let current = try await cache.read(lookup)
        if let current, current.state != .editing || Self.isOwnUpload(message, of: current) {
            return OpenedDraft(draft: current, droppedFormatting: false)
        }
        return try await importDraft(id, message: message, replacing: current)
    }

    private func importDraft(_ gmailDraftID: String, message: GmailMessage, replacing existing: LocalDraft?) async throws -> OpenedDraft {
        let accountID = accountID
        let headers = OriginalMessage(message)
        let body = try await body(of: message)
        var document = ComposeDocument()
        var quotedHTML: String?
        var quotedPlainText: String?
        var droppedFormatting = false
        if let html = body.html {
            let imported = HTMLImporter.importHTML(html)
            document = imported.document
            quotedHTML = imported.quotedTail
            quotedPlainText = imported.quotedTail.map { HTMLImporter.importHTML($0, detachingQuote: false).document.plainText() }
            droppedFormatting = imported.droppedFormatting
        } else if let text = body.plainText {
            document = ComposeDocument(plainText: text)
        }
        // With unsaved changes, the open copy keeps its ID and window.
        let localID = existing.flatMap { $0.hasUnsavedChanges ? nil : $0.id } ?? UUID().uuidString
        let imported = LocalDraft(
            id: localID,
            accountID: accountID,
            kind: .edit,
            content: DraftContent(
                to: headers.to,
                cc: headers.cc,
                bcc: message.header("Bcc").map(EmailAddress.parseList) ?? [],
                subject: headers.subject,
                body: document
            ),
            rfcMessageID: headers.messageID ?? MIMEMessage.newMessageID(for: sender),
            gmailDraftID: gmailDraftID,
            savedMessageID: message.id,
            threadID: message.threadId,
            inReplyTo: headers.inReplyTo,
            references: headers.references,
            quotedHTML: quotedHTML,
            quotedPlainText: quotedPlainText,
            now: now()
        )
        let files = MIMEParts.attachments(of: message).filter { !$0.isInline }
        let copies = try await download(files, of: message, for: localID)
        let record = DraftRecord(accountID: accountID, id: gmailDraftID, messageID: message.id, threadID: message.threadId)
        let metadata = try? Mapping.message(message, accountID: accountID)
        let now = now()
        let result: (draft: LocalDraft, removed: [OutgoingAttachment], copiedID: String?, stale: Set<String>, imported: Bool)
        do {
            result = try await write { tx in
                let current = try tx.localDraft(gmailDraftID: gmailDraftID, accountID: accountID)
                if let current {
                    // Another open imported it while this one downloaded.
                    let replaced = current != existing
                    // A save of the open copy that's uploading has already picked
                    // this Gmail draft, and its answer is recorded on the open copy.
                    // If the other app's change outlasts it, the next save keeps both.
                    let uploading = try tx.composeRows(localDraftID: current.id)
                        .contains { $0.kind == .saveDraft && $0.state == .sending }
                    if replaced || uploading { return (current, copies, nil, [], false) }
                }
                var removed: [OutgoingAttachment] = []
                var copiedID: String?
                var stale = Set([try tx.draft(id: gmailDraftID, accountID: accountID)?.messageID].compactMap { $0 })
                if let current {
                    if let saved = current.savedMessageID { stale.insert(saved) }
                    if current.id == localID {
                        removed = try tx.deleteLocalDraft(id: current.id)
                    } else {
                        try tx.returnToEditing(localDraftID: current.id, forgettingGmailDraft: true)
                        _ = try tx.enqueueSave(localDraftID: current.id, now: now, notBefore: now)
                        copiedID = current.id
                    }
                }
                try tx.insertLocalDraft(imported)
                for copy in copies { _ = try tx.addOutgoingAttachment(copy, now: now) }
                let revision = try tx.localDraft(id: localID)?.revision ?? imported.revision
                stale.remove(message.id)
                let threads = try tx.deleteMessages(ids: stale, accountID: accountID)
                stale.formUnion(try tx.recordDraftSave(record, localDraftID: localID, revision: revision, message: metadata))
                try tx.rebuildThreads(threads, accountID: accountID)
                return (try tx.localDraft(id: localID) ?? imported, removed, copiedID, stale, true)
            }
        } catch {
            removeFiles(copies)
            throw error
        }
        let deleted = deletedMessageIDs
        deleted.withLock { $0.formUnion(result.stale) }
        removeFiles(result.removed)
        if let copiedID = result.copiedID {
            continuation.yield(.draftCopied(localDraftID: copiedID))
            scheduleSending()
        }
        return OpenedDraft(draft: result.draft, droppedFormatting: droppedFormatting && result.imported)
    }

    // MARK: Files

    /// Copies a message's files under `outgoingDirectory` for a local draft.
    /// A file that can't be fetched fails the whole copy, so a draft never
    /// goes out missing one.
    private func download(_ parts: [AttachmentPart], of message: GmailMessage, for localDraftID: String) async throws -> [OutgoingAttachment] {
        var copies: [OutgoingAttachment] = []
        do {
            for part in parts {
                let data: Data
                if let attachmentID = part.attachmentID {
                    data = try await gmail.attachment(messageID: message.id, attachmentID: attachmentID)
                } else if let inline = message.payload.flatMap({ Self.part(part.partID, in: $0) })?.body?.decodedData {
                    data = inline
                } else {
                    throw GmailError.decoding("Attachment data")
                }
                let path = Self.outgoingPath(for: localDraftID, filename: part.filename)
                let url = outgoingDirectory.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                copies.append(OutgoingAttachment(localDraftID: localDraftID, filename: part.filename, mimeType: part.mimeType, size: data.count, path: path))
            }
        } catch {
            removeFiles(copies)
            throw error
        }
        return copies
    }

    /// Copies another draft's files under `directory` for `localDraftID`.
    /// The caller removes the copies if one fails.
    private func copyFiles(_ files: [OutgoingAttachment], for localDraftID: String, into directory: URL) throws -> [OutgoingAttachment] {
        try files.map { file in
            let path = Self.outgoingPath(for: localDraftID, filename: file.filename)
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try FileManager.default.copyItem(at: outgoingDirectory.appending(path: file.path), to: url)
            } catch CocoaError.fileReadNoSuchFile {
                throw ComposeError.missingAttachment(file.filename)
            }
            return OutgoingAttachment(localDraftID: localDraftID, filename: file.filename, mimeType: file.mimeType, size: file.size, path: path)
        }
    }

    /// The part with `id` in a `full`-format payload.
    static func part(_ id: String, in part: MessagePart) -> MessagePart? {
        if part.partId == id { return part }
        for child in part.parts ?? [] {
            if let found = Self.part(id, in: child) { return found }
        }
        return nil
    }

    private func removeFiles(_ attachments: [OutgoingAttachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: outgoingDirectory.appending(path: attachment.path))
        }
    }
}

extension LocalDraft.Kind {
    init(_ kind: ReplyKind) {
        switch kind {
        case .reply: self = .reply
        case .replyAll: self = .replyAll
        case .forward: self = .forward
        }
    }
}

extension OriginalMessage {
    /// The original as cached, for replying without a request.
    init(_ record: MessageRecord, body: MessageBodyRecord) {
        self.init(
            threadID: record.threadID,
            from: EmailAddress.parseList(record.sender),
            replyTo: record.replyTo.map(EmailAddress.parseList) ?? [],
            to: EmailAddress.parseList(record.recipients),
            cc: record.cc.map(EmailAddress.parseList) ?? [],
            subject: record.subject,
            date: record.date == .distantPast ? nil : record.date,
            messageID: record.rfcMessageID,
            inReplyTo: record.inReplyTo,
            references: record.referencesHeader.map(Self.messageIDs) ?? [],
            body: ExtractedBody(html: body.html, plainText: body.plainText)
        )
    }
}
