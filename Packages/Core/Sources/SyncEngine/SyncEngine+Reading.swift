import Foundation
import GmailAPI
import MailStore
import MessageContent

struct ReadingLoad {
    let id: UUID
    let task: Task<Void, any Error>
    let foreground: Bool
    let enrichCached: Bool
    var waiters: Set<UUID>
}

extension SyncEngine {
    /// Warms a small ordered lookahead without recording a read or an open.
    /// Replacing the list cancels work that no reader still needs.
    public func prefetchThreads(_ threadIDs: [String]) {
        guard !isStopped else { return }
        let targets = Array(threadIDs.removingDuplicates().prefix(4))
        guard targets != prefetchTargets else { return }
        prefetchTargets = targets
        prefetchTask?.cancel()
        let generation = UUID()
        prefetchGeneration = generation
        guard !targets.isEmpty else { prefetchTask = nil; return }
        prefetchTask = Task {
            defer { if prefetchGeneration == generation { prefetchTask = nil } }
            await withTaskGroup(of: Void.self) { group in
                var remaining = targets.makeIterator()
                for _ in 0..<2 {
                    if let id = remaining.next() { group.addTask { try? await self.prepareReadingThread(id) } }
                }
                for await _ in group {
                    guard !Task.isCancelled, !isStopped else { group.cancelAll(); return }
                    if let id = remaining.next() { group.addTask { try? await self.prepareReadingThread(id) } }
                }
            }
        }
    }

    /// A UI prefetch may join the engine's hydration without recording an
    /// open or changing read state. Required text is enough for preparation.
    public func prepareReadingThread(_ threadID: String) async throws {
        try await loadReadingThread(threadID, enrichCached: false, foreground: false)
    }

    /// Callers share one fetch. A reader replaces a queued background fetch
    /// so its requests can use the interactive quota allowance immediately.
    func loadReadingThread(_ threadID: String, enrichCached: Bool, foreground: Bool) async throws {
        guard !isStopped, !Task.isCancelled else { throw CancellationError() }
        if foreground, let background = readingLoads[threadID], !background.foreground {
            retiredReadingLoads[background.id] = background.task
            background.task.cancel()
            readingLoads[threadID] = nil
        }
        let waiter = UUID()
        let load: ReadingLoad
        if var existing = readingLoads[threadID] {
            existing.waiters.insert(waiter)
            readingLoads[threadID] = existing
            load = existing
        } else {
            let id = UUID()
            let task = Task {
                defer { finishReadingLoad(threadID, id: id) }
                try await GmailRequestBudget.$priority.withValue(foreground ? .interactive : .background) {
                    try await hydrateReadingThread(threadID, enrichCached: enrichCached, includesOptionalImages: foreground)
                }
            }
            load = ReadingLoad(id: id, task: task, foreground: foreground, enrichCached: enrichCached, waiters: [waiter])
            readingLoads[threadID] = load
        }
        defer { releaseReadingWaiter(threadID, loadID: load.id, waiter: waiter) }
        try await withTaskCancellationHandler {
            try await load.task.value
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.releaseReadingWaiter(threadID, loadID: load.id, waiter: waiter) }
        }
        // An enrichment caller may have joined a cached-body-only check.
        if enrichCached, !load.enrichCached {
            try await loadReadingThread(threadID, enrichCached: true, foreground: foreground)
        }
    }

    private func finishReadingLoad(_ threadID: String, id: UUID) {
        if readingLoads[threadID]?.id == id { readingLoads[threadID] = nil }
        retiredReadingLoads[id] = nil
    }

    private func releaseReadingWaiter(_ threadID: String, loadID: UUID, waiter: UUID) {
        guard var load = readingLoads[threadID], load.id == loadID else { return }
        load.waiters.remove(waiter)
        if load.waiters.isEmpty {
            retiredReadingLoads[load.id] = load.task
            readingLoads[threadID] = nil
            load.task.cancel()
        } else { readingLoads[threadID] = load }
    }

    /// One full fetch serves every gap in a conversation: bodies the cache
    /// lacks, and cached bodies whose inline pictures and invitation were never
    /// read. A conversation with neither costs no request.
    private func hydrateReadingThread(_ threadID: String, enrichCached: Bool, includesOptionalImages: Bool) async throws {
        let accountID = accountID
        let snapshot = try await cache.read { tx in
            (missing: Set(try tx.messageIDsWithoutBody(threadID: threadID, accountID: accountID)),
             unenriched: Set(try tx.unenrichedBodyMessageIDs(threadID: threadID, accountID: accountID)),
             versions: Dictionary(uniqueKeysWithValues: try tx.messages(threadID: threadID, accountID: accountID).map { ($0.id, $0.historyID) }))
        }
        // A plain open fetches only for a missing body, and enriches the rest
        // while it is at it. An enrichment call also fetches for those alone.
        guard !snapshot.missing.isEmpty || (enrichCached && !snapshot.unenriched.isEmpty) else { return }
        let wanted = snapshot.missing.union(snapshot.unenriched)
        try Task.checkCancellation()
        let deleted = deletedMessageIDs
        let thread: GmailThread
        do { thread = try await gmail.thread(id: threadID, format: .full) }
        catch GmailError.notFound {
            try await write { tx in
                let ids = try tx.messages(threadID: threadID, accountID: accountID)
                    .filter { snapshot.versions[$0.id] == $0.historyID }.map(\.id)
                deleted.withLock { $0.formUnion(ids) }
                try tx.deleteAnalyticsMessages(messageIDs: ids, accountID: accountID)
                try tx.rebuildThreads(try tx.deleteMessages(ids: ids, accountID: accountID), accountID: accountID)
            }
            return
        }
        guard thread.id == threadID, let messages = thread.messages else { throw GmailError.decoding("Thread messages") }
        let fetchedAt = now()
        var updates: [CacheTransaction.MessageUpdate] = []
        var bodies: [String: MessageBodyRecord] = [:]
        var calendars: [String: MessageCalendarRecord] = [:]
        var attachments: [String: [AttachmentRecord]] = [:]
        for message in messages {
            try Task.checkCancellation()
            guard message.threadId == threadID else { throw GmailError.decoding("Message thread identity") }
            do { try await ingestReadReceipt(message) }
            catch is CancellationError { throw CancellationError() }
            catch { /* A queued receipt download retries on the next sync pass. */ }
            updates.append(try Mapping.message(message, accountID: accountID))
            guard wanted.contains(message.id) else { continue }
            // A cached body needs only the parts its invitation may live in.
            let needsBody = snapshot.missing.contains(message.id)
            var parts: [String: Data] = [:]
            if needsBody {
                for id in MIMEParts.requiredAttachmentIDs(of: message).sorted() {
                    try Task.checkCancellation()
                    parts[id] = try await gmail.attachment(messageID: message.id, attachmentID: id)
                }
            }
            var attempted = Set<String>()
            while let id = CalendarParts.requiredAttachmentID(of: message, attachments: parts, attemptedAttachmentIDs: attempted) {
                try Task.checkCancellation()
                attempted.insert(id)
                parts[id] = try await gmail.attachment(messageID: message.id, attachmentID: id)
            }
            if needsBody {
                bodies[message.id] = Mapping.body(message, accountID: accountID, fetchedAt: fetchedAt, attachments: parts)
                attachments[message.id] = Mapping.attachments(message, accountID: accountID)
            }
            if let invitation = CalendarParts.invitation(in: message, attachments: parts) {
                calendars[message.id] = MessageCalendarRecord(accountID: accountID, messageID: message.id, invitation: invitation)
            }
        }
        let versions = try await write { [updates, bodies, calendars, attachments] tx -> [String: Int64] in
            let gone = deleted.withLock { $0 }
            let live = try updates.filter { update in
                guard !gone.contains(update.record.id) else { return false }
                if snapshot.versions[update.record.id] != nil, try tx.message(id: update.record.id, accountID: accountID) == nil { return false }
                return true
            }
            let threads = try tx.upsertMessages(live)
            var versions: [String: Int64] = [:]
            for update in live where wanted.contains(update.record.id) {
                let id = update.record.id
                guard let current = try tx.message(id: id, accountID: accountID) else { continue }
                let stored = try tx.body(messageID: id, accountID: accountID)
                if let body = bodies[id] {
                    // A label change can advance history while the immutable
                    // body is in flight. Fill the gap without replacing a body
                    // another load stored since the snapshot.
                    guard stored == nil || current.historyID <= update.record.historyID else { continue }
                    try tx.saveBodies([body], calendars: calendars[id].map { [$0] } ?? [])
                    try tx.replaceMIMEResources([], messageID: id, accountID: accountID)
                    try tx.replaceAttachments(attachments[id] ?? [], messageID: id, accountID: accountID)
                } else {
                    // A body cached before its pictures and invitation were
                    // read. The payload is immutable, so the invitation holds
                    // whatever version the metadata has reached.
                    guard stored != nil else { continue }
                    if let calendar = calendars[id] {
                        if try tx.messageCalendar(messageID: id, accountID: accountID) != calendar { try tx.saveMessageCalendar(calendar) }
                    } else {
                        try tx.deleteMessageCalendar(messageID: id, accountID: accountID)
                    }
                }
                versions[id] = current.historyID
            }
            try tx.rebuildThreads(threads, accountID: accountID)
            return versions
        }
        // The cache observation can now display text while optional pictures load.
        let readyForImages = messages.filter { message in
            versions[message.id] != nil && (includesOptionalImages || InlineMIMEResources.parts(of: message).allSatisfy { $0.inlineData != nil })
        }
        try await hydrateReadingImages(readyForImages, versions: versions)
    }

    /// Stores a message's inline pictures and marks its body enriched in one
    /// write, so later opens of the conversation need no request. A picture
    /// Gmail no longer has is marked too, so it is not asked for on every open;
    /// a transient failure leaves the mark off and the next open retries.
    func hydrateReadingImages(_ messages: [GmailMessage], versions: [String: Int64]) async throws {
        let accountID = accountID
        let deleted = deletedMessageIDs
        for message in messages {
            guard let version = versions[message.id] else { continue }
            try Task.checkCancellation()
            do {
                let resources: [MIMEInlineResourceRecord]?
                do { resources = try await inlineResources(in: message) }
                catch GmailError.notFound, GmailError.decoding { resources = nil }
                let enrichedAt = now()
                try await write { tx in
                    guard !deleted.withLock({ $0.contains(message.id) }),
                          let live = try tx.message(id: message.id, accountID: accountID),
                          live.threadID == message.threadId, live.historyID == version,
                          try tx.body(messageID: message.id, accountID: accountID) != nil else { return }
                    if let resources { try tx.replaceMIMEResources(resources, messageID: message.id, accountID: accountID) }
                    try tx.setBodyEnrichedAt(enrichedAt, messageID: message.id, accountID: accountID)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Left unmarked, so the next explicit open retries. */ }
        }
    }
}
