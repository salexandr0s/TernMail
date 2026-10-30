import Foundation
import GmailAPI
import MailStore
import MessageContent

extension SyncEngine {
    static let attachmentPageSize = 25

    /// Runs one bounded history page and one historical listing page. Both
    /// checkpoints are durable; callers can retry after a restart or failure.
    /// File bytes are requested only by the separate content/download APIs.
    @discardableResult
    public func indexAttachments(retryNow: Bool = false) async throws -> AttachmentIndexState {
        try checkAttachmentAccess()
        if let attachmentIndexPass { return try await attachmentIndexPass.value }
        let task = Task {
            defer { attachmentIndexPass = nil }
            return try await attachmentIndexStep(retryNow: retryNow)
        }
        attachmentIndexPass = task
        return try await task.value
    }

    func startAttachmentIndexing() {
        guard attachmentIndexTask == nil else { return }
        attachmentIndexTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                let state = try? await self.indexAttachments(retryNow: first)
                first = false
                let delay: Duration
                if let retry = state?.retryAfter, retry > Date() {
                    delay = .seconds(min(60, max(3, retry.timeIntervalSinceNow)))
                } else {
                    let caughtUp = state?.isComplete == true && state?.historyPageToken == nil && state?.pendingMessageIDs.isEmpty == true
                    delay = caughtUp ? .seconds(60) : .seconds(3)
                }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    /// Opens an uncached originating conversation through the same hydration
    /// and cache-hold path used by assistant citations and mail search.
    public func loadAttachmentSource(_ threadID: String) async throws {
        try checkAttachmentAccess()
        try await assistantLoadSource(threadID)
        try checkAttachmentAccess()
    }

    func checkAttachmentAccess() throws {
        if isStopped || stopRequested.withLock({ $0 }) || Task.isCancelled { throw CancellationError() }
    }

    private func attachmentIndexStep(retryNow: Bool) async throws -> AttachmentIndexState {
        let accountID = accountID
        var state = try await cache.read { try $0.attachmentIndexState(accountID: accountID) }
            ?? AttachmentIndexState(accountID: accountID)
        if !retryNow, let retry = state.retryAfter, retry > now() { return state }
        do {
            if state.historyID == nil {
                let profile = try await gmail.profile()
                guard let cursor = Int64(profile.historyId), cursor > 0 else { throw SyncError.invalidHistoryID }
                state.historyID = cursor
                state.generation = UUID().uuidString
                // This baseline precedes the first listing request, so new
                // arrivals during a long backfill are recovered by history.
                try await saveAttachmentState(state)
            }
            state = try await indexAttachmentHistory(state)
            if !state.isComplete { state = try await indexHistoricalAttachmentPage(state) }
            state.failureCount = 0
            state.retryAfter = nil
            state.lastError = nil
            if state.isComplete, state.historyPageToken == nil, state.pendingMessageIDs.isEmpty,
               state.lastReconciledAt == nil, let generation = state.generation {
                state.lastReconciledAt = now()
                let saved = state
                try await write { tx in
                    try tx.finishLibraryGeneration(accountID: accountID, generation: generation)
                    try tx.saveAttachmentIndexState(saved)
                }
            } else {
                try await saveAttachmentState(state)
            }
            return state
        } catch is CancellationError { throw CancellationError() }
        catch {
            try checkAttachmentAccess()
            // A page may have committed before a later request failed. Read
            // that checkpoint instead of rolling it back with our old copy.
            state = try await cache.read { try $0.attachmentIndexState(accountID: accountID) } ?? state
            state.failureCount += 1
            state.lastError = Self.attachmentIndexMessage(for: error)
            let requiresSignIn = (error as? GmailError) == .unauthorized || (error as? GmailError)?.isMissingScope == true
            let seconds = min(1_800.0, 30 * pow(2, Double(min(state.failureCount - 1, 6))))
            state.retryAfter = requiresSignIn ? .distantFuture : now().addingTimeInterval(seconds)
            try await saveAttachmentState(state)
            throw error
        }
    }

    private func indexAttachmentHistory(_ original: AttachmentIndexState) async throws -> AttachmentIndexState {
        var state = original
        if state.pendingMessageIDs.isEmpty { state = try await queueAttachmentHistory(state) }
        let wanted = Array(state.pendingMessageIDs.prefix(Self.attachmentPageSize))
        guard !wanted.isEmpty else { return state }
        let fetched = try await fetchAttachmentMetadata(wanted)
        state.pendingMessageIDs.removeFirst(wanted.count)
        if state.pendingMessageIDs.isEmpty, state.historyPageToken == nil { state.updatedAt = now() }
        state.lastError = nil
        state.retryAfter = nil
        let saved = state
        let accountID = accountID
        let deleted = deletedMessageIDs
        try await write { tx in
            deleted.withLock { $0.formUnion(fetched.missing) }
            try tx.deleteLibraryAttachments(messageIDs: Array(fetched.missing), accountID: accountID)
            for entry in fetched.entries where !deleted.withLock({ $0.contains(entry.message.id) }) {
                try tx.replaceLibraryAttachments(entry.attachments, message: entry.message,
                    labelIDs: entry.labelIDs, generation: saved.generation)
            }
            try tx.saveAttachmentIndexState(saved)
        }
        return state
    }

    /// Save provider progress together with pending IDs before downloading any
    /// metadata. A bulk history record cannot turn one step into an unbounded
    /// sequence of message requests, and a restart resumes this exact queue.
    private func queueAttachmentHistory(_ original: AttachmentIndexState) async throws -> AttachmentIndexState {
        guard let cursor = original.historyID else { return original }
        try checkAttachmentAccess()
        let page: HistoryPage
        do {
            page = try await gmail.attachmentHistory(startHistoryID: String(cursor), pageToken: original.historyPageToken)
        } catch GmailError.notFound {
            let profile = try await gmail.profile()
            guard let historyID = Int64(profile.historyId), historyID > 0 else { throw SyncError.invalidHistoryID }
            var reset = AttachmentIndexState(accountID: accountID)
            reset.historyID = historyID
            reset.generation = UUID().uuidString
            reset.lastReconciledAt = nil
            try await saveAttachmentState(reset)
            return reset
        } catch GmailError.http(status: 400, _) where original.historyPageToken != nil {
            var reset = original
            reset.historyPageToken = nil
            reset.historyTargetID = nil
            try await saveAttachmentState(reset)
            throw GmailError.invalidRequest("Attachment history pagination expired")
        }
        guard let latest = Int64(page.historyId), latest >= cursor else { throw SyncError.invalidHistoryID }
        let records = page.history ?? []
        let gone = Set(records.flatMap { $0.messagesDeleted ?? [] }.map(\.message.id))
        var state = original
        state.pendingMessageIDs = records.flatMap { $0.messagesAdded ?? [] }.map(\.message.id)
            .filter { !gone.contains($0) }.removingDuplicates()
        state.historyPageToken = page.nextPageToken
        state.historyTargetID = max(latest, state.historyTargetID ?? cursor)
        if state.historyPageToken == nil {
            state.historyID = state.historyTargetID
            state.historyTargetID = nil
            if state.pendingMessageIDs.isEmpty { state.updatedAt = now() }
        }
        state.lastError = nil
        state.retryAfter = nil
        let saved = state
        let accountID = accountID
        let deleted = deletedMessageIDs
        try await write { tx in
            deleted.withLock { $0.formUnion(gone) }
            try tx.deleteLibraryAttachments(messageIDs: Array(gone), accountID: accountID)
            for record in records {
                guard let historyID = Int64(record.id), historyID > 0 else { throw SyncError.invalidHistoryID }
                for change in record.labelsAdded ?? [] where !gone.contains(change.message.id) {
                    try tx.applyLibraryLabelChange(messageID: change.message.id, added: change.labelIds,
                        removed: [], historyID: historyID, accountID: accountID)
                }
                for change in record.labelsRemoved ?? [] where !gone.contains(change.message.id) {
                    try tx.applyLibraryLabelChange(messageID: change.message.id, added: [],
                        removed: change.labelIds, historyID: historyID, accountID: accountID)
                }
            }
            try tx.saveAttachmentIndexState(saved)
        }
        return state
    }

    private func indexHistoricalAttachmentPage(_ original: AttachmentIndexState) async throws -> AttachmentIndexState {
        try checkAttachmentAccess()
        let page: MessageListPage
        do {
            page = try await gmail.listMessages(query: "has:attachment", labelIDs: [], includeSpamTrash: true,
                pageToken: original.nextPageToken, maxResults: Self.attachmentPageSize)
        } catch GmailError.http(status: 400, _) where original.nextPageToken != nil {
            var reset = original
            reset.nextPageToken = nil
            reset.indexedMessageCount = 0
            reset.generation = UUID().uuidString
            reset.lastReconciledAt = nil
            try await saveAttachmentState(reset)
            throw GmailError.invalidRequest("Attachment listing pagination expired")
        }
        let ids = (page.messages ?? []).map(\.id).removingDuplicates()
        let fetched = try await fetchAttachmentMetadata(ids)
        var state = original
        state.nextPageToken = page.nextPageToken
        state.indexedMessageCount += ids.count
        state.isComplete = page.nextPageToken == nil
        state.lastError = nil
        state.retryAfter = nil
        let saved = state
        let accountID = accountID
        let deleted = deletedMessageIDs
        try await write { tx in
            deleted.withLock { $0.formUnion(fetched.missing) }
            try tx.deleteLibraryAttachments(messageIDs: Array(fetched.missing), accountID: accountID)
            for entry in fetched.entries where !deleted.withLock({ $0.contains(entry.message.id) }) {
                try tx.replaceLibraryAttachments(entry.attachments, message: entry.message,
                    labelIDs: entry.labelIDs, generation: saved.generation)
            }
            try tx.saveAttachmentIndexState(saved)
        }
        return state
    }

    private struct AttachmentMetadata: Sendable {
        let message: MessageRecord
        let labelIDs: [String]
        let attachments: [AttachmentRecord]
    }

    private func fetchAttachmentMetadata(_ ids: [String]) async throws -> (entries: [AttachmentMetadata], missing: Set<String>) {
        var entries: [AttachmentMetadata] = []
        var missing = Set<String>()
        for start in stride(from: 0, to: ids.count, by: Self.attachmentPageSize) {
            try checkAttachmentAccess()
            if start > 0 { try await sleep(.milliseconds(250)) }
            let chunk = Array(ids[start..<min(start + Self.attachmentPageSize, ids.count)])
            let responses = try await gmail.attachmentMetadata(ids: chunk)
            for id in chunk {
                guard let response = responses[id] else { throw GmailError.missingBatchPart }
                switch response {
                case .failure(.notFound): missing.insert(id)
                case .failure(let error): throw error
                case .success(let message):
                    guard message.id == id, let payload = message.payload else {
                        throw GmailError.decoding("Attachment message identity or structure")
                    }
                    try Self.validateAttachmentTree(payload)
                    let mapped = try Mapping.message(message, accountID: accountID)
                    let attachments = Mapping.attachments(message, accountID: accountID).filter { attachment in
                        guard !attachment.isInline else { return false }
                        // CID images are embedded content even when a sender
                        // incorrectly supplies an attachment disposition.
                        guard attachment.mimeType.hasPrefix("image/"),
                              let part = Self.part(attachment.partID, in: payload) else { return true }
                        return part.header("Content-ID") == nil
                    }
                    entries.append(AttachmentMetadata(message: mapped.record, labelIDs: mapped.labelIDs, attachments: attachments))
                }
            }
        }
        return (entries, missing)
    }

    private static func validateAttachmentTree(_ part: MessagePart, depth: Int = 0) throws {
        if depth >= 20, (part.mimeType ?? "").lowercased().hasPrefix("multipart/"), part.parts == nil {
            throw GmailError.decoding("Attachment MIME nesting exceeds metadata limit")
        }
        for child in part.parts ?? [] { try validateAttachmentTree(child, depth: depth + 1) }
    }

    private func saveAttachmentState(_ state: AttachmentIndexState) async throws {
        try checkAttachmentAccess()
        try await write { try $0.saveAttachmentIndexState(state) }
    }

    private static func attachmentIndexMessage(for error: any Error) -> String {
        if (error as? GmailError)?.isMissingScope == true {
            return "Gmail no longer allows attachment access. Sign in again to continue."
        }
        switch error as? GmailError {
        case .invalidRequest?: return "Gmail's listing changed. Tern will resume indexing shortly."
        case .decoding?: return "Some attachment metadata could not be read. Coverage is incomplete; try again."
        default: return Self.message(for: error)
        }
    }
}
