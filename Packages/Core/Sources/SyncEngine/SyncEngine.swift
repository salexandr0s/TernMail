import Foundation
import GmailAPI
import MailStore
import MessageContent
import os

public enum SyncEvent: Sendable, Equatable {
    case syncStarted
    case syncFinished(Date)
    case syncFailed(String)
    /// Gmail refused a change for good. A conversation or label goes back
    /// to how it was; for a settings change, the message names what Gmail
    /// didn't save.
    case actionFailed(String)
    /// A draft was sent.
    case draftSent(localDraftID: String)
    /// Gmail refused a draft, or it was sent or deleted in another app. The
    /// draft is back to editing, and its window shows `message`.
    case draftFailed(localDraftID: String, message: String)
    /// Another app changed the draft's Gmail copy, so Tern kept that one and
    /// saves this draft as a new one.
    case draftCopied(localDraftID: String)
}

enum SyncError: Error, Equatable {
    case invalidHistoryID
}

/// Keeps one account's cache in step with Gmail and sends queued changes.
///
/// Passes run one at a time. A pass fetches first and then writes its changes
/// with the new history cursor in one transaction, so a failed pass leaves the
/// cursor where it was.
public actor SyncEngine {
    /// The threading headers let a reply answer a message without fetching it.
    static let metadataHeaders = ["From", "To", "Cc", "Subject", "Date", "Message-ID", "In-Reply-To", "References", "Reply-To"]
    static let inboxCap = 5000
    /// Releasing a search hold keeps what this lists, so both use one window.
    static let recentQuery = "newer_than:\(CacheHolds.recentDays)d"
    /// Metadata fetched per request group during a full sync.
    static let fullSyncChunk = 100

    public nonisolated let events: AsyncStream<SyncEvent>
    let continuation: AsyncStream<SyncEvent>.Continuation
    let accountID: String
    /// The From address of every draft.
    let sender: EmailAddress
    /// Where compose windows copy attached files. `OutgoingAttachment.path` is relative to it.
    let outgoingDirectory: URL
    let gmail: any GmailService
    /// Filter, vacation and signature calls. Without them, settings rows wait.
    let settings: (any SettingsService)?
    /// Where a signature Gmail accepted is recorded for compose. Without it,
    /// the next identity refresh picks the signature up.
    let accounts: AccountStore?
    let cache: MailCache
    let now: @Sendable () -> Date
    let undoHold: TimeInterval
    let sendsAutomatically: Bool

    private var pass: Task<Void, any Error>?
    private var pollTask: Task<Void, Never>?
    private var hasStarted = false
    private var writesInFlight = 0
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    var drainTasks: [PendingAction.Lane: Task<Void, Never>] = [:]
    var wakeRequests = Set<PendingAction.Lane>()
    /// Sends under way, so `stop()` can let them finish. The drain task and
    /// `sendWaitingDraftsNow()` can each be running one.
    var sendsInFlight = 0
    var sendWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by `stop()`: the compose lane starts no further rows.
    var isStoppingDrafts = false
    /// Earliest next save per local draft. Large messages save at most every
    /// `largeSaveInterval`, since each save uploads the attachments again.
    var nextLargeSave: [String: Date] = [:]
    /// Undo receipts exist only for this engine's lifetime. Remember rejected
    /// and consumed row IDs even after history has removed the queue rows.
    var unavailableUndoIDs = Set<Int64>()
    var undoReceipts: [Int64: WeakActionReceipt] = [:]
    private(set) var isStopped = false
    /// Set as `stop()` begins. A lock, so another engine's write that adds
    /// rows for this account can check it inside its transaction.
    let stopRequested = OSAllocatedUnfairLock(initialState: false)
    /// Accessed only inside the cache's serialized writes. The lock safely
    /// carries deletion knowledge into their Sendable closures. Gmail message
    /// IDs are never reused; forgetting one could resurrect deleted mail.
    let deletedMessageIDs = OSAllocatedUnfairLock(initialState: Set<String>())
    /// Conversations an open search or list shows. A lock, so the write that
    /// releases expired holds reads the set as it is then.
    let visibleThreadIDs = OSAllocatedUnfairLock(initialState: Set<String>())

    /// - Parameters:
    ///   - settings: Defaults to `gmail` when it makes the settings calls.
    ///   - undoHold: Seconds a new action waits before it is sent, so undo can cancel it.
    ///   - sendsAutomatically: Tests turn this off and call `sendDueActions()` themselves.
    public init(
        accountID: String,
        sender: EmailAddress,
        outgoingDirectory: URL,
        gmail: any GmailService,
        settings: (any SettingsService)? = nil,
        accounts: AccountStore? = nil,
        cache: MailCache,
        undoHold: TimeInterval = 2,
        sendsAutomatically: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.sender = sender
        self.outgoingDirectory = outgoingDirectory
        self.gmail = gmail
        self.settings = settings ?? gmail as? any SettingsService
        self.accounts = accounts
        self.cache = cache
        self.undoHold = undoHold
        self.sendsAutomatically = sendsAutomatically
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SyncEvent.self, bufferingPolicy: .bufferingNewest(16))
    }

    // MARK: Scheduling

    /// Resumes interrupted sends and syncs now and every `pollInterval`.
    public func start(pollInterval: Duration = .seconds(60)) async {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        let accountID = accountID
        do {
            try await write { tx in
                try tx.requeueInterruptedActions(accountID: accountID)
                try tx.clearLabelAliases(accountID: accountID)
            }
        } catch {
            hasStarted = false
            if !isStopped { continuation.yield(.syncFailed(Self.message(for: error))) }
            return
        }
        guard !isStopped else { return }
        scheduleSending()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncReportingErrors()
                try? await Task.sleep(for: pollInterval)
                if self == nil { return }
            }
        }
    }

    /// Cancels polling, sending and any running pass, and returns once they
    /// have finished, so the caller can delete the account's data safely. A
    /// send that is already uploading finishes first, so its outcome is known.
    public func stop() async {
        stopRequested.withLock { $0 = true }
        isStoppingDrafts = true
        if sendsInFlight > 0 {
            await withCheckedContinuation { sendWaiters.append($0) }
        }
        isStopped = true
        pollTask?.cancel()
        pollTask = nil
        let drains = Array(drainTasks.values)
        drainTasks = [:]
        drains.forEach { $0.cancel() }
        let running = pass
        running?.cancel()
        for drain in drains { await drain.value }
        _ = try? await running?.value
        if writesInFlight > 0 {
            await withCheckedContinuation { writeWaiters.append($0) }
        }
        continuation.finish()
    }

    /// Every engine write goes through here, so nothing lands after `stop()`.
    func write<T: Sendable>(_ updates: @escaping @Sendable (CacheTransaction) throws -> T) async throws -> T {
        if isStopped || Task.isCancelled { throw CancellationError() }
        writesInFlight += 1
        defer {
            writesInFlight -= 1
            if writesInFlight == 0 {
                let waiters = writeWaiters
                writeWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
        return try await cache.write(updates)
    }

    /// Runs a pass and reports the outcome on `events` instead of throwing.
    public func syncReportingErrors() async {
        continuation.yield(.syncStarted)
        do {
            try await sync()
            continuation.yield(.syncFinished(now()))
        } catch is CancellationError {
            return
        } catch {
            continuation.yield(.syncFailed(Self.message(for: error)))
        }
    }

    /// Runs one pass, or waits for the pass already running.
    public func sync() async throws {
        if isStopped { throw CancellationError() }
        if let pass { return try await pass.value }
        let task = Task { try await runPass() }
        pass = task
        defer { pass = nil }
        try await task.value
    }

    // MARK: Passes

    private func runPass() async throws {
        let passStart = now()
        let accountID = accountID
        let state = try await cache.read { tx in try tx.syncState(accountID: accountID) }
        if let state {
            if try await incrementalSync(from: state.historyID, passStart: passStart) == nil {
                try await fullSync(reset: true)
            }
        } else {
            try await fullSync(reset: false)
        }
        try await releaseExpiredHolds()
    }

    /// Lists INBOX, the last 30 days and every draft and stores their metadata,
    /// then deletes cached messages the listings did not return. That covers
    /// both an expired cursor (`reset`) and a first sync that quit partway through.
    private func fullSync(reset: Bool) async throws {
        let passStart = now()
        let accountID = accountID
        let deleted = deletedMessageIDs
        let profile = try await gmail.profile()
        guard let historyID = Int64(profile.historyId), historyID > 0 else { throw SyncError.invalidHistoryID }
        let labels = try await fetchLabels()

        let inbox = try await listMessageIDs(labelIDs: [SystemLabel.inbox], query: nil, includeSpamTrash: false, limit: Self.inboxCap)
        let recent = try await listMessageIDs(labelIDs: [], query: Self.recentQuery, includeSpamTrash: true)
        // Older drafts stay cached, so the Drafts label is complete.
        let drafts = try await listDrafts()
        let listed = (inbox + recent + drafts.map(\.messageID)).removingDuplicates()
        // Messages pending actions target and messages in held conversations
        // stay cached even when unlisted. Refetch them as well: their stored
        // labels may predate changes the lost history held, and a 404 means
        // Gmail deleted the message.
        let (targeted, held) = try await cache.read { tx in
            (try tx.messageIDsTargetedByPendingActions(accountID: accountID), try tx.messageIDsInHeldThreads(accountID: accountID))
        }
        var wanted = listed + targeted.union(held).subtracting(listed).sorted()

        var gone = Set<String>()
        var fetchedIDs = Set<String>()
        var updates: [CacheTransaction.MessageUpdate] = []
        let kept = Set(listed)
        while true {
            for start in stride(from: 0, to: wanted.count, by: Self.fullSyncChunk) {
                let chunk = Array(wanted[start..<min(start + Self.fullSyncChunk, wanted.count)])
                let (fetched, missing) = try await fetchMetadata(chunk)
                updates += fetched
                fetchedIDs.formUnion(chunk)
                gone.formUnion(missing)
            }
            let finishedAt = now()
            let remaining = try await write { [gone, fetchedIDs, updates] tx -> Set<String> in
                // Recheck inside the committing transaction. User actions and
                // thread loads can have added protected targets while we awaited.
                let remaining = try tx.messageIDsTargetedByPendingActions(accountID: accountID).subtracting(fetchedIDs)
                guard remaining.isEmpty else { return remaining }
                try tx.replaceLabels(labels, accountID: accountID)
                try tx.replaceDrafts(drafts, accountID: accountID)
                deleted.withLock { $0.formUnion(gone) }
                let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
                var threads = try tx.upsertMessages(live)
                threads.formUnion(try tx.deleteMessages(ids: gone, accountID: accountID))
                threads.formUnion(try tx.deleteMessages(notIn: kept, accountID: accountID, through: historyID))
                try tx.dropSentActions(sentBefore: passStart, accountID: accountID)
                try tx.rebuildThreads(threads, accountID: accountID)
                try tx.saveCursor(historyID: historyID, accountID: accountID, fullSyncAt: finishedAt, reset: reset)
                return []
            }
            guard !remaining.isEmpty else { return }
            wanted = remaining.sorted()
        }
    }

    /// Applies `history.list` from `cursor`. Returns nil when Gmail no longer
    /// has history that old, otherwise whether anything changed.
    private func incrementalSync(from cursor: Int64, passStart: Date) async throws -> Bool? {
        var records: [HistoryRecord] = []
        var latest = cursor
        var pageToken: String?
        repeat {
            let page: HistoryPage
            do {
                page = try await gmail.history(startHistoryID: String(cursor), pageToken: pageToken)
            } catch GmailError.notFound {
                return nil
            }
            records += page.history ?? []
            guard let pageHistoryID = Int64(page.historyId), pageHistoryID > 0, pageHistoryID >= cursor else {
                throw SyncError.invalidHistoryID
            }
            latest = max(latest, pageHistoryID)
            pageToken = page.nextPageToken
        } while pageToken != nil

        let accountID = accountID
        let cached = try await cache.read { tx in try tx.cachedMessageIDs(accountID: accountID) }
        let changes = try HistoryChanges(records: records, cachedMessageIDs: cached)
        let (fetched, missing) = try await fetchMetadata(changes.messagesToFetch)
        let gone = changes.deletedIDs.union(missing)
        let deleted = deletedMessageIDs
        // Labels can change without any message history (for example a rename).
        let labels = try await fetchLabels()

        try await write { [latest] tx in
            try tx.replaceLabels(labels, accountID: accountID)
            deleted.withLock { $0.formUnion(gone) }
            var threads = Set<String>()
            for change in changes.labelChanges {
                if let threadID = try tx.applyLabelChange(
                    messageID: change.messageID, added: change.added, removed: change.removed,
                    historyID: change.historyID, accountID: accountID
                ) {
                    threads.insert(threadID)
                }
            }
            threads.formUnion(try tx.deleteMessages(ids: gone, accountID: accountID))
            let live = deleted.withLock { ids in fetched.filter { !ids.contains($0.record.id) } }
            threads.formUnion(try tx.upsertMessages(live))
            // Store the cursor even when nothing changed, so the next pass starts later.
            try tx.saveCursor(historyID: latest, accountID: accountID)
            try tx.dropSentActions(sentBefore: passStart, accountID: accountID)
            try tx.rebuildThreads(threads, accountID: accountID)
        }
        return !records.isEmpty
    }

    /// Fetches a complete label snapshot before the pass commits anything.
    private func fetchLabels() async throws -> [LabelRecord] {
        let accountID = accountID
        let list = try await gmail.labels()
        let detailed = try await gmail.labels(ids: list.map(\.id))
        return try list.compactMap { label in
            switch detailed[label.id] {
            case .success(let full)?:
                guard full.id == label.id else { throw GmailError.decoding("Label identity") }
                return Mapping.label(full, accountID: accountID)
            case .failure(.notFound)?:
                return nil // Deleted after labels.list, before labels.get.
            case .failure(let error)?:
                throw error
            case nil:
                throw GmailError.missingBatchPart
            }
        }
    }

    private func listMessageIDs(labelIDs: [String], query: String?, includeSpamTrash: Bool, limit: Int? = nil) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            let page = try await gmail.listMessages(
                query: query,
                labelIDs: labelIDs,
                includeSpamTrash: includeSpamTrash,
                pageToken: pageToken,
                maxResults: 500
            )
            ids += (page.messages ?? []).map(\.id)
            pageToken = page.nextPageToken
        } while pageToken != nil && (limit.map { ids.count < $0 } ?? true)
        return limit.map { Array(ids.prefix($0)) } ?? ids
    }

    /// Every Gmail draft, with the message it holds.
    func listDrafts() async throws -> [DraftRecord] {
        var drafts: [DraftRecord] = []
        var pageToken: String?
        repeat {
            let page = try await gmail.drafts(query: nil, pageToken: pageToken, maxResults: 500)
            for draft in page.drafts ?? [] {
                guard let message = draft.message else { throw GmailError.decoding("Draft message") }
                drafts.append(DraftRecord(accountID: accountID, id: draft.id, messageID: message.id, threadID: message.threadId))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return drafts
    }

    /// Relists Gmail's drafts, so a draft made in another app can be opened.
    public func refreshDrafts() async throws {
        if isStopped || Task.isCancelled { throw CancellationError() }
        let drafts = try await listDrafts()
        let accountID = accountID
        try await write { tx in try tx.replaceDrafts(drafts, accountID: accountID) }
    }

    /// Metadata for `ids`, plus the IDs Gmail no longer has. Any other failed
    /// part fails the pass.
    func fetchMetadata(
        _ ids: [String]
    ) async throws -> (updates: [CacheTransaction.MessageUpdate], missing: Set<String>) {
        guard !ids.isEmpty else { return ([], []) }
        let results = try await gmail.messages(ids: ids, format: .metadata, metadataHeaders: Self.metadataHeaders)
        var updates: [CacheTransaction.MessageUpdate] = []
        var missing = Set<String>()
        for id in ids {
            switch results[id] {
            case .success(let message)?:
                guard message.id == id else { throw GmailError.decoding("Message identity") }
                updates.append(try Mapping.message(message, accountID: accountID))
            case .failure(.notFound)?:
                missing.insert(id)
            case nil:
                throw GmailError.missingBatchPart
            case .failure(let error)?:
                throw error
            }
        }
        return (updates, missing)
    }

    // MARK: Opening a thread

    /// Fetches bodies the cache lacks for a thread the user opened, and marks
    /// the thread read.
    public func openThread(_ threadID: String) async throws {
        if isStopped || Task.isCancelled { throw CancellationError() }
        let accountID = accountID
        let deleted = deletedMessageIDs
        let openedAt = now()
        let opened = try await write { tx in
            let missing = try tx.messageIDsWithoutBody(threadID: threadID, accountID: accountID)
            let versions = Dictionary(uniqueKeysWithValues: try tx.messages(threadID: threadID, accountID: accountID).map { ($0.id, $0.historyID) })
            if try tx.thread(id: threadID, accountID: accountID)?.isUnread == true {
                // Reading state and recording mark-read are one transaction, so
                // a user command cannot land between them and be overwritten.
                _ = try tx.enqueue(
                    .modifyThreads, accountID: accountID, threadIDs: [threadID],
                    remove: [SystemLabel.unread], now: openedAt, notBefore: openedAt
                )
            }
            return (missing: missing, versions: versions)
        }
        scheduleSending()
        guard !opened.missing.isEmpty else { return }
        if isStopped || Task.isCancelled { throw CancellationError() }

        let thread: GmailThread
        do {
            thread = try await gmail.thread(id: threadID, format: .full)
        } catch GmailError.notFound {
            try await write { tx in
                // A slow 404 describes the request's starting state. Preserve
                // messages that a newer sync or thread response has since stored.
                let ids = try tx.messages(threadID: threadID, accountID: accountID)
                    .filter { opened.versions[$0.id] == $0.historyID }.map(\.id)
                deleted.withLock { $0.formUnion(ids) }
                try tx.rebuildThreads(try tx.deleteMessages(ids: ids, accountID: accountID), accountID: accountID)
            }
            return
        }
        let fetchedAt = now()
        var updates: [CacheTransaction.MessageUpdate] = []
        var bodies: [MessageBodyRecord] = []
        var attachments: [String: [AttachmentRecord]] = [:]
        guard thread.id == threadID, let messages = thread.messages else { throw GmailError.decoding("Thread messages") }
        for message in messages {
            guard message.threadId == threadID else { throw GmailError.decoding("Message thread identity") }
            let update = try Mapping.message(message, accountID: accountID)
            updates.append(update)
            var textParts: [String: Data] = [:]
            for id in MIMEParts.requiredAttachmentIDs(of: message).sorted() {
                if isStopped || Task.isCancelled { throw CancellationError() }
                textParts[id] = try await gmail.attachment(messageID: message.id, attachmentID: id)
            }
            bodies.append(Mapping.body(message, accountID: accountID, fetchedAt: fetchedAt, attachments: textParts))
            attachments[message.id] = Mapping.attachments(message, accountID: accountID)
        }
        try await write { [updates, bodies, attachments] tx in
            // Decide inside the same serialized write as ingestion, so a delete
            // committed while this request was awaiting cannot be overwritten.
            let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
            let liveIDs = Set(live.map(\.record.id))
            let threads = try tx.upsertMessages(live)
            try tx.saveBodies(bodies.filter { liveIDs.contains($0.messageID) })
            for (messageID, records) in attachments where liveIDs.contains(messageID) {
                try tx.replaceAttachments(records, messageID: messageID, accountID: accountID)
            }
            try tx.rebuildThreads(threads, accountID: accountID)
        }
    }

    // MARK: Messages

    /// User-facing text for a failure. Never includes message content or addresses.
    static func message(for error: any Error) -> String {
        switch error as? GmailError {
        case .transport?:
            "Tern can't reach Gmail. Check your internet connection."
        case .rateLimited?:
            "Gmail asked Tern to slow down. It will try again shortly."
        case .server?, .missingBatchPart?:
            "Gmail had a problem. Tern will try again."
        case .unauthorized?:
            "Gmail didn't accept your sign-in."
        default:
            (error as? LocalizedError)?.errorDescription ?? "Tern couldn't sync with Gmail."
        }
    }
}

/// What one run of history records asks the cache to do.
struct HistoryChanges {
    struct LabelChange: Equatable {
        let messageID: String
        let added: [String]
        let removed: [String]
        /// The history record's ID, which becomes the message's stored history ID.
        let historyID: Int64
    }

    /// New messages, and messages with label changes that the cache lacks.
    let messagesToFetch: [String]
    let deletedIDs: Set<String>
    /// Changes to cached messages, in history order. Messages being fetched
    /// are left out, since their fresh metadata already has the final labels.
    let labelChanges: [LabelChange]

    init(records: [HistoryRecord], cachedMessageIDs: Set<String>) throws {
        let deleted = Set(records.flatMap { $0.messagesDeleted ?? [] }.map(\.message.id))
        var fetch: [String] = []
        for record in records {
            fetch += (record.messagesAdded ?? []).map(\.message.id)
            let changed = (record.labelsAdded ?? []) + (record.labelsRemoved ?? [])
            fetch += changed.map(\.message.id).filter { !cachedMessageIDs.contains($0) }
        }
        let toFetch = fetch.filter { !deleted.contains($0) }.removingDuplicates()
        let skipped = deleted.union(toFetch)

        var changes: [LabelChange] = []
        for record in records {
            guard let historyID = Int64(record.id), historyID > 0 else { throw SyncError.invalidHistoryID }
            for change in record.labelsAdded ?? [] {
                changes.append(LabelChange(
                    messageID: change.message.id, added: change.labelIds, removed: [], historyID: historyID
                ))
            }
            for change in record.labelsRemoved ?? [] {
                changes.append(LabelChange(
                    messageID: change.message.id, added: [], removed: change.labelIds, historyID: historyID
                ))
            }
        }
        messagesToFetch = toFetch
        deletedIDs = deleted
        labelChanges = changes.filter { cachedMessageIDs.contains($0.messageID) && !skipped.contains($0.messageID) }
    }
}
