import Foundation
import GmailAPI
import MailStore

public enum SyncEvent: Sendable, Equatable {
    case syncStarted
    case syncFinished(Date)
    case syncFailed(String)
    /// Gmail refused a change for good, so the cache put the thread back.
    case actionFailed(String)
}

enum SyncError: Error {
    case invalidHistoryID
}

/// Keeps one account's cache in step with Gmail and sends queued changes.
///
/// Passes run one at a time. A pass fetches first and then writes its changes
/// with the new history cursor in one transaction, so a failed pass leaves the
/// cursor where it was.
public actor SyncEngine {
    static let metadataHeaders = ["From", "To", "Cc", "Subject", "Date"]
    static let inboxCap = 5000
    static let recentQuery = "newer_than:30d"
    /// Messages fetched per cache write during a full sync, so the list fills in as it goes.
    static let fullSyncChunk = 100

    public nonisolated let events: AsyncStream<SyncEvent>
    let continuation: AsyncStream<SyncEvent>.Continuation
    let accountID: String
    let gmail: any GmailService
    let cache: MailCache
    let now: @Sendable () -> Date
    let undoHold: TimeInterval
    let sendsAutomatically: Bool

    private var pass: Task<Void, any Error>?
    private var pollTask: Task<Void, Never>?
    var drainTask: Task<Void, Never>?
    var wakeRequested = false

    /// - Parameters:
    ///   - undoHold: Seconds a new action waits before it is sent, so undo can cancel it.
    ///   - sendsAutomatically: Tests turn this off and call `sendDueActions()` themselves.
    public init(
        accountID: String,
        gmail: any GmailService,
        cache: MailCache,
        undoHold: TimeInterval = 2,
        sendsAutomatically: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.gmail = gmail
        self.cache = cache
        self.undoHold = undoHold
        self.sendsAutomatically = sendsAutomatically
        self.now = now
        (events, continuation) = AsyncStream.makeStream(of: SyncEvent.self, bufferingPolicy: .bufferingNewest(16))
    }

    // MARK: Scheduling

    /// Resumes interrupted sends and syncs now and every `pollInterval`.
    public func start(pollInterval: Duration = .seconds(60)) async {
        guard pollTask == nil else { return }
        let accountID = accountID
        _ = try? await cache.write { tx in try tx.requeueInterruptedActions(accountID: accountID) }
        scheduleSending()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncReportingErrors()
                try? await Task.sleep(for: pollInterval)
                if self == nil { return }
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        drainTask?.cancel()
        drainTask = nil
        continuation.finish()
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
        guard let state else {
            return try await fullSync(reset: false)
        }
        switch try await incrementalSync(from: state.historyID, passStart: passStart) {
        case nil:
            try await fullSync(reset: true)
        case true?:
            try await refreshLabels()
        case false?:
            break
        }
    }

    /// Lists INBOX and the last 30 days, then stores their metadata. With
    /// `reset`, which follows an expired cursor, messages the listings did not
    /// return are deleted, except those pending actions still target.
    private func fullSync(reset: Bool) async throws {
        let passStart = now()
        let accountID = accountID
        let profile = try await gmail.profile()
        guard let historyID = Int64(profile.historyId) else { throw SyncError.invalidHistoryID }
        try await refreshLabels()

        let inbox = try await listMessageIDs(labelIDs: [SystemLabel.inbox], query: nil, includeSpamTrash: false)
        let recent = try await listMessageIDs(labelIDs: [], query: Self.recentQuery, includeSpamTrash: true)
        let listed = (inbox + recent).removingDuplicates()

        for start in stride(from: 0, to: listed.count, by: Self.fullSyncChunk) {
            let chunk = Array(listed[start..<min(start + Self.fullSyncChunk, listed.count)])
            let updates = try await fetchMetadata(chunk)
            try await cache.write { tx in
                try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: accountID)
            }
        }

        let kept = Set(listed)
        let finishedAt = now()
        try await cache.write { tx in
            if reset {
                try tx.rebuildThreads(try tx.deleteMessages(notIn: kept, accountID: accountID), accountID: accountID)
            }
            try tx.saveCursor(historyID: historyID, accountID: accountID, fullSyncAt: finishedAt, reset: reset)
            try tx.dropSentActions(sentBefore: passStart, accountID: accountID)
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
            latest = Int64(page.historyId) ?? latest
            pageToken = page.nextPageToken
        } while pageToken != nil

        let accountID = accountID
        let cached = try await cache.read { tx in try tx.cachedMessageIDs(accountID: accountID) }
        let changes = HistoryChanges(records: records, cachedMessageIDs: cached)
        let fetched = try await fetchMetadata(changes.messagesToFetch)

        try await cache.write { [latest] tx in
            var threads = Set<String>()
            for change in changes.labelChanges {
                if let threadID = try tx.applyLabelChange(
                    messageID: change.messageID, added: change.added, removed: change.removed, accountID: accountID
                ) {
                    threads.insert(threadID)
                }
            }
            threads.formUnion(try tx.deleteMessages(ids: changes.deletedIDs, accountID: accountID))
            threads.formUnion(try tx.upsertMessages(fetched))
            // Store the cursor even when nothing changed, so the next pass starts later.
            try tx.saveCursor(historyID: latest, accountID: accountID)
            try tx.dropSentActions(sentBefore: passStart, accountID: accountID)
            try tx.rebuildThreads(threads, accountID: accountID)
        }
        return !records.isEmpty
    }

    /// Replaces the label list, with counts from `labels.get`.
    private func refreshLabels() async throws {
        let accountID = accountID
        let list = try await gmail.labels()
        let detailed = try await gmail.labels(ids: list.map(\.id))
        let records = list.map { label in
            let full = (try? detailed[label.id]?.get()) ?? label
            return Mapping.label(full, accountID: accountID)
        }
        try await cache.write { tx in try tx.replaceLabels(records, accountID: accountID) }
    }

    private func listMessageIDs(labelIDs: [String], query: String?, includeSpamTrash: Bool) async throws -> [String] {
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
        } while pageToken != nil && ids.count < Self.inboxCap
        return Array(ids.prefix(Self.inboxCap))
    }

    /// Metadata for `ids`. Messages deleted since they were listed are skipped;
    /// any other failed part fails the pass.
    private func fetchMetadata(_ ids: [String]) async throws -> [CacheTransaction.MessageUpdate] {
        guard !ids.isEmpty else { return [] }
        let results = try await gmail.messages(ids: ids, format: .metadata, metadataHeaders: Self.metadataHeaders)
        var updates: [CacheTransaction.MessageUpdate] = []
        for id in ids {
            switch results[id] {
            case .success(let message)?:
                if let update = Mapping.message(message, accountID: accountID) { updates.append(update) }
            case .failure(.notFound)?, nil:
                continue
            case .failure(let error)?:
                throw error
            }
        }
        return updates
    }

    // MARK: Opening a thread

    /// Fetches bodies the cache lacks for a thread the user opened, and marks
    /// the thread read.
    public func openThread(_ threadID: String) async throws {
        let accountID = accountID
        let (missing, isUnread) = try await cache.read { tx in
            (
                try tx.messageIDsWithoutBody(threadID: threadID, accountID: accountID),
                try tx.thread(id: threadID, accountID: accountID)?.isUnread ?? false
            )
        }
        if isUnread {
            try await enqueue(.markRead, threadIDs: [threadID], hold: 0)
        }
        guard !missing.isEmpty else { return }

        let thread = try await gmail.thread(id: threadID, format: .full)
        let fetchedAt = now()
        var updates: [CacheTransaction.MessageUpdate] = []
        var bodies: [MessageBodyRecord] = []
        for message in thread.messages ?? [] {
            guard let update = Mapping.message(message, accountID: accountID) else { continue }
            updates.append(update)
            bodies.append(Mapping.body(message, accountID: accountID, fetchedAt: fetchedAt))
        }
        try await cache.write { [updates, bodies] tx in
            let threads = try tx.upsertMessages(updates)
            try tx.saveBodies(bodies)
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
    }

    /// New messages, and messages with label changes that the cache lacks.
    let messagesToFetch: [String]
    let deletedIDs: Set<String>
    /// Changes to cached messages, in history order. Messages being fetched
    /// are left out, since their fresh metadata already has the final labels.
    let labelChanges: [LabelChange]

    init(records: [HistoryRecord], cachedMessageIDs: Set<String>) {
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
            for change in record.labelsAdded ?? [] {
                changes.append(LabelChange(messageID: change.message.id, added: change.labelIds, removed: []))
            }
            for change in record.labelsRemoved ?? [] {
                changes.append(LabelChange(messageID: change.message.id, added: [], removed: change.labelIds))
            }
        }
        messagesToFetch = toFetch
        deletedIDs = deleted
        labelChanges = changes.filter { cachedMessageIDs.contains($0.messageID) && !skipped.contains($0.messageID) }
    }
}
