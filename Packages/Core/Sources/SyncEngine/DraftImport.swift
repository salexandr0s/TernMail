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

    /// A sent message becomes a new independent draft with copied files and a new Message-ID.
    public func startAgain(messageID: String) async throws -> OpenedDraft {
        if LocalSend.isProvisional(messageID) { throw ComposeError.stillSending }
        let fetched = try await fullMessage(messageID)
        let message = fetched.message
        let original = fetched.original
        let imported = original.body.html.map { HTMLImporter.importHTML($0, detachingQuote: false, preservingInlineImages: true) }
        let body = imported?.document ?? ComposeDocument(plainText: original.body.plainText ?? "")
        let draft = LocalDraft(
            accountID: accountID, kind: .new,
            content: DraftContent(to: original.to, cc: original.cc,
                                  bcc: message.header("Bcc").map(EmailAddress.parseList) ?? [],
                                  subject: original.subject, body: body, fromAddress: sender.address),
            rfcMessageID: MIMEMessage.newMessageID(for: sender), now: now()
        )
        let referencedImages = Set(body.blocks.flatMap(\.runs).compactMap { $0.image?.contentID })
        let copies = try await downloadDraftParts(MIMEParts.attachments(of: message), of: message, references: referencedImages, for: draft.id)
        let date = now()
        do {
            try await write { [copies] tx in
                try tx.insertLocalDraft(draft)
                for copy in copies { _ = try tx.addOutgoingAttachment(copy, now: date) }
            }
        } catch { removeFiles(copies); throw error }
        return OpenedDraft(draft: draft, droppedFormatting: imported?.droppedFormatting ?? false)
    }

    /// Starts a reply or forward with everything it takes from its original,
    /// in one step. A compose window that opens before the original loads
    /// uses `insertReplyShell` and `completeReplyImport` instead.
    public func startReply(_ kind: ReplyKind, to messageID: String) async throws -> LocalDraft {
        let shell = try await insertReplyShell(kind, to: messageID)
        guard shell.importPending else { return shell }
        do {
            return try await completeReplyImport(localDraftID: shell.id)
        } catch {
            // Nothing is kept of a reply whose original can't be loaded.
            let removed = try? await write { tx in try tx.deleteLocalDraft(id: shell.id) }
            removeFiles(removed ?? [])
            throw error
        }
    }

    /// Starts a reply or forward without waiting for Gmail when the
    /// original's headers are cached. Its recipients, subject and threading
    /// are set, and `importPending` marks the quote and files as still to
    /// come (`completeReplyImport`). When the cache holds those too, or Gmail
    /// has to be asked for the headers, the draft comes back whole.
    public func insertReplyShell(_ kind: ReplyKind, to messageID: String) async throws -> LocalDraft {
        // Gmail doesn't know a provisional send yet, so it can't supply the original.
        if LocalSend.isProvisional(messageID) { throw ComposeError.stillSending }
        let accountID = accountID
        let record = try await cache.read { tx in try tx.message(id: messageID, accountID: accountID) }
        // A reply threads on the original's Message-ID, so without one cached
        // the headers come from Gmail.
        guard let record, record.rfcMessageID != nil else {
            let fetched = try await fullMessage(messageID)
            let draft = try await newReply(kind, to: messageID, from: fetched.original)
            let parts = try await originalParts(kind, of: messageID, for: draft.id, fetched: fetched)
            return try await insertReply(draft, with: parts)
        }
        var draft = try await newReply(kind, to: messageID, from: OriginalMessage(record, body: nil))
        if let parts = try await cachedParts(kind, of: messageID, for: draft.id) {
            return try await insertReply(draft, with: parts)
        }
        draft.importPending = true
        try await createDraft(draft)
        return draft
    }

    /// Adds what a reply or forward from `insertReplyShell` takes from its
    /// original: the quote, a forward's files and the quote's inline images.
    /// Edits made meanwhile stay, and a selection quoted in place of the
    /// whole message is set after this (`replaceSelectedQuote`). Returns the
    /// draft, as it is when nothing is pending or a discard has taken it.
    /// When the original can't be loaded this throws and the draft stays
    /// pending, to try again or go without (`skipReplyImport`).
    @discardableResult
    public func completeReplyImport(localDraftID: String) async throws -> LocalDraft {
        let accountID = accountID
        let stored = try await cache.read { tx in try tx.localDraft(id: localDraftID) }
        guard let draft = stored, draft.accountID == accountID else { throw ComposeError.draftGone }
        guard draft.importPending, let kind = ReplyKind(draft.kind), let source = draft.sourceMessageID else { return draft }
        let parts = try await originalParts(kind, of: source, for: localDraftID)
        let now = now()
        let completed: LocalDraft?
        do {
            completed = try await write { tx in
                try tx.completeImport(localDraftID: localDraftID, quotedHTML: parts.quotedHTML,
                                      quotedPlainText: parts.quotedPlainText, attachments: parts.copies, now: now)
            }
        } catch {
            removeFiles(parts.copies)
            throw error
        }
        if let completed { return completed }
        // A discard or another completion took the draft meanwhile.
        removeFiles(parts.copies)
        guard let current = try await cache.read({ tx in try tx.localDraft(id: localDraftID) }) else { throw ComposeError.draftGone }
        return current
    }

    /// Lets a reply or forward go out without what its original would add,
    /// for when `completeReplyImport` can't load it. Returns the draft.
    @discardableResult
    public func skipReplyImport(localDraftID: String) async throws -> LocalDraft {
        let accountID = accountID
        let now = now()
        return try await write { tx in
            guard let draft = try tx.localDraft(id: localDraftID), draft.accountID == accountID else { throw ComposeError.draftGone }
            let skipped = try tx.completeImport(localDraftID: localDraftID, quotedHTML: nil, quotedPlainText: nil, attachments: [], now: now)
            return skipped ?? draft
        }
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

    /// What a reply or forward takes from its original, with the files
    /// saved for its draft.
    private struct OriginalParts: Sendable {
        var quotedHTML: String
        var quotedPlainText: String
        var copies: [OutgoingAttachment]
    }

    /// A reply or forward to `messageID`, with its recipients, subject and
    /// threading from `original`, and nothing quoted yet.
    private func newReply(_ kind: ReplyKind, to messageID: String, from original: OriginalMessage) async throws -> LocalDraft {
        let identities = try await accounts?.identities(accountID: accountID).filter(\.canSend) ?? []
        let reply = ReplyBuilder.draft(kind, replyingTo: original, ownAddresses: Set([sender.address] + identities.map(\.address)))
        return LocalDraft(
            accountID: accountID,
            kind: LocalDraft.Kind(kind),
            content: DraftContent(to: reply.to, cc: reply.cc, subject: reply.subject),
            rfcMessageID: MIMEMessage.newMessageID(for: sender),
            threadID: reply.threadID,
            sourceMessageID: messageID,
            inReplyTo: reply.inReplyTo,
            references: reply.references,
            now: now()
        )
    }

    /// The quote and files a reply takes from its original when the cache
    /// holds all of them: the body, and the inline images the quote shows.
    /// Nil for a forward, whose files come from Gmail, and whenever
    /// something is missing.
    private func cachedParts(_ kind: ReplyKind, of messageID: String, for localDraftID: String) async throws -> OriginalParts? {
        guard kind != .forward else { return nil }
        let accountID = accountID
        let original = try await cache.read { tx -> OriginalMessage? in
            guard let record = try tx.message(id: messageID, accountID: accountID),
                  let body = try tx.body(messageID: messageID, accountID: accountID)
            else { return nil }
            return OriginalMessage(record, body: body)
        }
        guard let original else { return nil }
        let quote = ReplyBuilder.draft(kind, replyingTo: original, ownAddresses: [])
        let references = HTMLImporter.inlineImageContentIDs(in: quote.quotedHTML)
        var copies: [OutgoingAttachment] = []
        if !references.isEmpty {
            let resources = try await cache.mimeResources(messageID: messageID, accountID: accountID)
            guard references.isSubset(of: Set(resources.map(\.contentID))) else { return nil }
            copies = try copyInlineImages(resources.filter { references.contains($0.contentID) }, for: localDraftID)
        }
        return OriginalParts(quotedHTML: quote.quotedHTML, quotedPlainText: quote.quotedPlainText, copies: copies)
    }

    /// The quote and files a reply or forward takes from its original: from
    /// the cache when it holds all of them, otherwise from `fetched` or
    /// Gmail. A forward copies every file, a reply the inline images its
    /// quote shows.
    private func originalParts(
        _ kind: ReplyKind, of messageID: String, for localDraftID: String,
        fetched: (message: GmailMessage, original: OriginalMessage)? = nil
    ) async throws -> OriginalParts {
        if fetched == nil, let parts = try await cachedParts(kind, of: messageID, for: localDraftID) { return parts }
        let full = if let fetched { fetched } else { try await fullMessage(messageID) }
        let message = full.message
        let quote = ReplyBuilder.draft(kind, replyingTo: full.original, ownAddresses: [])
        let references = HTMLImporter.inlineImageContentIDs(in: quote.quotedHTML)
        var files = MIMEParts.attachments(of: message)
        if kind != .forward {
            files = files.filter { part in
                guard let raw = message.payload.flatMap({ Self.part(part.partID, in: $0) })?.header("Content-ID") else { return false }
                return references.contains(raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")))
            }
        }
        let copies = try await downloadDraftParts(files, of: message, references: references, for: localDraftID)
        return OriginalParts(quotedHTML: quote.quotedHTML, quotedPlainText: quote.quotedPlainText, copies: copies)
    }

    /// Inserts a reply or forward with what it takes from its original.
    private func insertReply(_ reply: LocalDraft, with parts: OriginalParts) async throws -> LocalDraft {
        var draft = reply
        draft.quotedHTML = parts.quotedHTML
        draft.quotedPlainText = parts.quotedPlainText
        let now = now()
        do {
            try await write { [draft] tx in
                try tx.insertLocalDraft(draft)
                for copy in parts.copies { _ = try tx.addOutgoingAttachment(copy, now: now) }
            }
        } catch {
            removeFiles(parts.copies)
            throw error
        }
        return try await cache.read { [draft] tx in try tx.localDraft(id: draft.id) } ?? draft
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
            let imported = HTMLImporter.importHTML(html, preservingInlineImages: true)
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
                body: document, fromAddress: headers.from.first?.address
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
        let files = MIMEParts.attachments(of: message)
        let references = Set(document.blocks.flatMap(\.runs).compactMap { $0.image?.contentID })
            .union(HTMLImporter.inlineImageContentIDs(in: quotedHTML ?? ""))
        let copies = try await downloadDraftParts(files, of: message, references: references, for: localID)
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

    private func downloadDraftParts(_ parts: [AttachmentPart], of message: GmailMessage,
                                    references: Set<String>, for localDraftID: String) async throws -> [OutgoingAttachment] {
        var copies = try await download(parts, of: message, for: localDraftID)
        var assigned = Set<String>()
        for index in copies.indices where parts[index].isInline {
            guard let raw = message.payload.flatMap({ Self.part(parts[index].partID, in: $0) })?.header("Content-ID") else { continue }
            let cid = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
            if InlineImageReference(contentID: cid).isValid, references.contains(cid), assigned.insert(cid).inserted { copies[index].contentID = cid }
        }
        return copies
    }

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

    /// Copies cached inline images under `outgoingDirectory` for a local draft.
    private func copyInlineImages(_ resources: [MIMEInlineResourceRecord], for localDraftID: String) throws -> [OutgoingAttachment] {
        var copies: [OutgoingAttachment] = []
        do {
            for resource in resources {
                let filename = "Inline Image"
                let path = Self.outgoingPath(for: localDraftID, filename: filename)
                let url = outgoingDirectory.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try resource.data.write(to: url)
                copies.append(OutgoingAttachment(localDraftID: localDraftID, filename: filename, mimeType: resource.mimeType,
                                                 size: resource.data.count, path: path, contentID: resource.contentID))
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
            return OutgoingAttachment(localDraftID: localDraftID, filename: file.filename, mimeType: file.mimeType, size: file.size, path: path, contentID: file.contentID)
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

extension ReplyKind {
    /// The kind of reply or forward a draft was started as, or nil for other drafts.
    init?(_ kind: LocalDraft.Kind) {
        switch kind {
        case .reply: self = .reply
        case .replyAll: self = .replyAll
        case .forward: self = .forward
        case .new, .edit, .invitationReply: return nil
        }
    }
}

extension OriginalMessage {
    /// The original as cached, for replying without a request. Without its
    /// body it gives a reply's headers but nothing to quote.
    init(_ record: MessageRecord, body: MessageBodyRecord?) {
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
            body: ExtractedBody(html: body?.html, plainText: body?.plainText)
        )
    }
}
