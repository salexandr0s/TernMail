import Foundation
import GmailAPI
import MailStore
import MessageContent

extension SyncEngine {
    /// Hydrates a source only when the user opens its citation. The normal reader
    /// can then load bodies and apply the user's usual read-state behavior.
    public func assistantLoadSource(_ threadID: String) async throws {
        try checkAssistantAccess()
        let (updates, missing) = try await fetchThreadMetadata([threadID])
        try checkAssistantAccess()
        guard !missing.contains(threadID), !updates.isEmpty else { throw AssistantMailError.unavailable }
        let accountID = accountID
        let deleted = deletedMessageIDs
        let expiry = now().addingTimeInterval(CacheHolds.searchLifetime)
        try await write { tx in
            let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
            guard !live.isEmpty else { throw AssistantMailError.unavailable }
            let changed = try tx.upsertMessages(live)
            try tx.holdSearchResults([threadID], until: expiry, accountID: accountID)
            try tx.rebuildThreads(changed, accountID: accountID)
        }
        try checkAssistantAccess()
    }

    /// Fetches MIME metadata for a cited file, without downloading its bytes.
    public func assistantLoadAttachmentSource(threadID: String, messageID: String, partID: String) async throws {
        try checkAssistantAccess()
        let response = try await gmail.attachmentMetadata(ids: [messageID])
        try checkAssistantAccess()
        guard let result = response[messageID] else { throw AssistantMailError.unavailable }
        let message = try result.get()
        guard message.id == messageID, message.threadId == threadID else { throw AssistantMailError.invalidTarget }
        let attachments = Mapping.attachments(message, accountID: accountID)
        guard attachments.contains(where: { $0.partID == partID }) else { throw AssistantMailError.invalidTarget }
        let accountID = accountID
        try await write { tx in
            guard try tx.message(id: messageID, accountID: accountID)?.threadID == threadID else {
                throw AssistantMailError.invalidTarget
            }
            try tx.replaceAttachments(attachments, messageID: messageID, accountID: accountID)
        }
        try checkAssistantAccess()
    }

    /// Reads full content directly, including uncached threads. It does not mark
    /// mail read, change selection, or ingest a partial thread into the cache.
    public func assistantReadThread(_ threadID: String) async throws -> AssistantThread {
        try checkAssistantAccess()
        let thread = try await gmail.thread(id: threadID, format: .full)
        try checkAssistantAccess()
        guard thread.id == threadID, let messages = thread.messages,
              messages.allSatisfy({ $0.threadId == threadID }) else { throw AssistantMailError.invalidTarget }
        var result: [AssistantMessage] = []
        var remaining = AssistantMailLimits.charactersPerThread
        // Reserve content for the current outcome before older quoted history.
        // Restore chronological order after allocating the shared text budget.
        for message in messages.suffix(AssistantMailLimits.messagesPerThread).reversed() {
            try checkAssistantAccess()
            let body = try await assistantBody(message)
            let text = body.value.plainText ?? SearchText.body(html: body.value.html, plainText: nil)
            let limit = min(remaining, AssistantMailLimits.charactersPerMessage)
            let limited = String(text.prefix(limit))
            remaining -= limited.count
            let attachments = Mapping.attachments(message, accountID: accountID)
            let cut = text.count > limit || attachments.count > AssistantMailLimits.attachmentsPerMessage
            result.append(AssistantMessage(
                messageID: message.id, threadID: threadID, sender: message.header("From") ?? "",
                recipients: message.header("To") ?? "", subject: message.header("Subject") ?? "",
                date: message.date, text: limited,
                attachments: Array(attachments.prefix(AssistantMailLimits.attachmentsPerMessage)),
                truncated: cut || !body.limitations.isEmpty, limitations: body.limitations
            ))
        }
        try checkAssistantAccess()
        return AssistantThread(
            accountID: accountID, threadID: threadID, messages: result.reversed(), totalMessages: messages.count,
            truncated: result.count < messages.count || result.contains(where: \.truncated),
            snippet: String((messages.last?.snippet ?? "").prefix(1_000)),
            labelIDs: Array(Set(messages.flatMap { $0.labelIds ?? [] })).sorted()
        )
    }

    /// Resolves the attachment from Gmail; callers never provide filesystem paths
    /// or trusted attachment records. Nothing is written to disk.
    public func assistantReadAttachment(messageID: String, partID: String, expectedThreadID: String? = nil) async throws -> AssistantAttachment {
        let message = try await assistantMessage(messageID)
        guard expectedThreadID == nil || expectedThreadID == message.threadId,
              let attachment = MIMEParts.attachments(of: message).first(where: { $0.partID == partID }),
              let payload = message.payload, let part = Self.part(partID, in: payload)
        else { throw AssistantMailError.invalidTarget }
        guard attachment.size <= AssistantMailLimits.attachmentBytes else { throw AssistantMailError.attachmentTooLarge }
        let data: Data
        if let inline = part.body?.decodedData { data = inline }
        else if let id = part.body?.attachmentId {
            data = try await gmail.attachment(messageID: messageID, attachmentID: id)
        } else { throw AssistantMailError.unavailable }
        try checkAssistantAccess()
        guard data.count <= AssistantMailLimits.attachmentBytes else { throw AssistantMailError.attachmentTooLarge }
        return AssistantAttachment(
            accountID: accountID, threadID: message.threadId, messageID: messageID, partID: partID,
            filename: attachment.filename, mimeType: attachment.mimeType, data: data
        )
    }

    /// Creates and queues an editable draft atomically. The caller reserves one
    /// stable ID per tool call so a retry adopts the same draft.
    public func assistantPrepareDraft(
        id: String, replyKind: ReplyKind?, messageID: String?, expectedThreadID: String?,
        recipients: [EmailAddress], subject: String, text: String,
        isAuthorized: @escaping @Sendable () async -> Bool
    ) async throws -> LocalDraft {
        try checkAssistantAccess()
        guard await isAuthorized() else { throw AssistantMailError.accessChanged }
        try checkAssistantAccess()
        if let existing = try await cache.read({ try $0.localDraft(id: id) }) {
            guard existing.accountID == accountID else { throw AssistantMailError.invalidTarget }
            guard await isAuthorized() else { throw AssistantMailError.accessChanged }
            try checkAssistantAccess()
            return existing
        }
        var draft: LocalDraft
        if let replyKind {
            guard replyKind != .forward, let messageID else { throw AssistantMailError.invalidTarget }
            let message = try await assistantMessage(messageID)
            guard expectedThreadID == nil || message.threadId == expectedThreadID else { throw AssistantMailError.invalidTarget }
            let body = try await assistantBody(message)
            var original = OriginalMessage(message)
            original.body = body.value
            let reply = ReplyBuilder.draft(replyKind, replyingTo: original, ownAddresses: [sender.address])
            draft = LocalDraft(
                id: id, accountID: accountID, kind: LocalDraft.Kind(replyKind),
                content: DraftContent(to: reply.to, cc: reply.cc, subject: reply.subject, body: ComposeDocument(plainText: text)),
                rfcMessageID: MIMEMessage.newMessageID(for: sender), threadID: reply.threadID,
                sourceMessageID: messageID, inReplyTo: reply.inReplyTo, references: reply.references,
                quotedHTML: reply.quotedHTML, quotedPlainText: reply.quotedPlainText, now: now()
            )
        } else {
            guard messageID == nil, expectedThreadID == nil, !recipients.isEmpty,
                  recipients.allSatisfy(\.isValid) else { throw AssistantMailError.invalidTarget }
            draft = LocalDraft(
                id: id, accountID: accountID, kind: .new,
                content: DraftContent(to: recipients, subject: subject, body: ComposeDocument(plainText: text)),
                rfcMessageID: MIMEMessage.newMessageID(for: sender), now: now()
            )
        }
        // Nonempty generated content must survive the composer's untouched-draft cleanup.
        draft.revision = 1
        guard await isAuthorized() else { throw AssistantMailError.accessChanged }
        try checkAssistantAccess()
        let prepared = draft
        let timestamp = now()
        let result = try await write { tx in
            if let existing = try tx.localDraft(id: id) {
                guard existing.accountID == prepared.accountID else { throw AssistantMailError.invalidTarget }
                return existing
            }
            try tx.insertLocalDraft(prepared)
            _ = try tx.enqueueSave(localDraftID: id, now: timestamp, notBefore: timestamp)
            return prepared
        }
        scheduleSending()
        return result
    }

    private func assistantMessage(_ messageID: String) async throws -> GmailMessage {
        try checkAssistantAccess()
        let results = try await gmail.messages(ids: [messageID], format: .full, metadataHeaders: [])
        try checkAssistantAccess()
        guard let result = results[messageID] else { throw AssistantMailError.unavailable }
        let message = try result.get()
        guard message.id == messageID else { throw AssistantMailError.invalidTarget }
        return message
    }

    private func assistantBody(_ message: GmailMessage) async throws -> (value: ExtractedBody, limitations: [String]) {
        var textParts: [String: Data] = [:]
        var limitations: [String] = []
        var remaining = AssistantMailLimits.bodyBytes
        let ids = MIMEParts.requiredAttachmentIDs(of: message).sorted()
        for id in ids.prefix(8) {
            try checkAssistantAccess()
            let declared = Self.assistantPartSize(attachmentID: id, part: message.payload)
            guard declared <= remaining else {
                limitations.append("A message body part exceeded the reading limit.")
                continue
            }
            do {
                let data = try await gmail.attachment(messageID: message.id, attachmentID: id)
                try checkAssistantAccess()
                guard data.count <= remaining else {
                    limitations.append("A message body part exceeded the reading limit.")
                    continue
                }
                remaining -= data.count
                textParts[id] = data
            } catch is CancellationError { throw CancellationError() }
            catch {
                try checkAssistantAccess()
                limitations.append("A message body part could not be downloaded.")
            }
        }
        if ids.count > 8 { limitations.append("Some message body parts were omitted.") }
        let value = MIMEParts.body(of: message, attachments: textParts)
        if value.html != nil && value.plainText == nil && (value.html?.count ?? 0) > SearchText.limit {
            limitations.append("HTML text extraction may omit content beyond the reading limit.")
        }
        return (value, limitations)
    }

    private func checkAssistantAccess() throws {
        if isStopped || stopRequested.withLock({ $0 }) || Task.isCancelled { throw CancellationError() }
    }

    private static func assistantPartSize(attachmentID: String, part: MessagePart?) -> Int {
        guard let part else { return 0 }
        if part.body?.attachmentId == attachmentID { return part.body?.size ?? 0 }
        return (part.parts ?? []).map { assistantPartSize(attachmentID: attachmentID, part: $0) }.max() ?? 0
    }
}
