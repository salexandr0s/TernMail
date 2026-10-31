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
            for threadID in targets {
                guard !Task.isCancelled, !isStopped else { return }
                do { try await loadReadingThread(threadID, enrichCached: false, foreground: false) }
                catch is CancellationError { if Task.isCancelled { return } }
                catch { /* An explicit open can retry a failed warmup. */ }
            }
        }
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
                    try await hydrateReadingThread(threadID, enrichCached: enrichCached)
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

    private func hydrateReadingThread(_ threadID: String, enrichCached: Bool) async throws {
        let accountID = accountID
        let snapshot = try await cache.read { tx in
            (missing: try tx.messageIDsWithoutBody(threadID: threadID, accountID: accountID),
             versions: Dictionary(uniqueKeysWithValues: try tx.messages(threadID: threadID, accountID: accountID).map { ($0.id, $0.historyID) }))
        }
        guard !snapshot.missing.isEmpty else {
            if enrichCached { try await enrichReadingThreadIfNeeded(threadID) }
            return
        }
        try Task.checkCancellation()
        let deleted = deletedMessageIDs
        let thread: GmailThread
        do { thread = try await gmail.thread(id: threadID, format: .full) }
        catch GmailError.notFound {
            try await write { tx in
                let ids = try tx.messages(threadID: threadID, accountID: accountID)
                    .filter { snapshot.versions[$0.id] == $0.historyID }.map(\.id)
                deleted.withLock { $0.formUnion(ids) }
                try tx.rebuildThreads(try tx.deleteMessages(ids: ids, accountID: accountID), accountID: accountID)
            }
            return
        }
        guard thread.id == threadID, let messages = thread.messages else { throw GmailError.decoding("Thread messages") }
        let fetchedAt = now()
        var updates: [CacheTransaction.MessageUpdate] = []
        var bodies: [MessageBodyRecord] = []
        var calendars: [MessageCalendarRecord] = []
        var attachments: [String: [AttachmentRecord]] = [:]
        for message in messages {
            try Task.checkCancellation()
            guard message.threadId == threadID else { throw GmailError.decoding("Message thread identity") }
            updates.append(try Mapping.message(message, accountID: accountID))
            var parts: [String: Data] = [:]
            for id in MIMEParts.requiredAttachmentIDs(of: message).sorted() {
                try Task.checkCancellation()
                parts[id] = try await gmail.attachment(messageID: message.id, attachmentID: id)
            }
            var attempted = Set<String>()
            while let id = CalendarParts.requiredAttachmentID(of: message, attachments: parts, attemptedAttachmentIDs: attempted) {
                try Task.checkCancellation()
                attempted.insert(id)
                parts[id] = try await gmail.attachment(messageID: message.id, attachmentID: id)
            }
            bodies.append(Mapping.body(message, accountID: accountID, fetchedAt: fetchedAt, attachments: parts))
            if let invitation = CalendarParts.invitation(in: message, attachments: parts) {
                calendars.append(MessageCalendarRecord(accountID: accountID, messageID: message.id, invitation: invitation))
            }
            attachments[message.id] = Mapping.attachments(message, accountID: accountID)
        }
        let versions = try await write { [updates, bodies, calendars, attachments] tx -> [String: Int64] in
            let gone = deleted.withLock { $0 }
            let live = try updates.filter { update in
                guard !gone.contains(update.record.id) else { return false }
                let current = try tx.message(id: update.record.id, accountID: accountID)
                if snapshot.versions[update.record.id] != nil, current == nil { return false }
                return true
            }
            // A label change can advance history while the immutable message
            // body is in flight. Fill missing content without replacing newer
            // metadata or an already-cached newer body.
            let content = try live.filter { update in
                guard let current = try tx.message(id: update.record.id, accountID: accountID),
                      current.historyID > update.record.historyID else { return true }
                return try tx.body(messageID: update.record.id, accountID: accountID) == nil
            }
            let liveIDs = Set(content.map(\.record.id))
            let threads = try tx.upsertMessages(live)
            try tx.saveBodies(bodies.filter { liveIDs.contains($0.messageID) }, calendars: calendars)
            var versions: [String: Int64] = [:]
            for update in content {
                try tx.replaceMIMEResources([], messageID: update.record.id, accountID: accountID)
                try tx.replaceAttachments(attachments[update.record.id] ?? [], messageID: update.record.id, accountID: accountID)
                versions[update.record.id] = try tx.message(id: update.record.id, accountID: accountID)?.historyID
            }
            try tx.rebuildThreads(threads, accountID: accountID)
            return versions
        }
        for id in versions.keys {
            completedReadingVersions[id] = nil
            completedReadingOrder.removeAll { $0 == id }
        }
        // The cache observation can now display text while optional pictures load.
        try await hydrateReadingImages(messages, versions: versions)
    }

    func enrichReadingThreadIfNeeded(_ threadID: String) async throws {
        let accountID = accountID
        let versions = try await cache.read { tx in
            Dictionary(uniqueKeysWithValues: try tx.messages(threadID: threadID, accountID: accountID).map { ($0.id, $0.historyID) })
        }
        guard !versions.isEmpty, !versions.allSatisfy({ completedReadingVersions[$0.key] == $0.value }) else { return }
        try await refreshReadingEnrichment(threadID: threadID, versions: versions)
    }

    func hydrateReadingImages(_ messages: [GmailMessage], versions: [String: Int64]) async throws {
        let accountID = accountID
        let deleted = deletedMessageIDs
        for message in messages {
            guard let version = versions[message.id] else { continue }
            try Task.checkCancellation()
            do {
                let resources = try await inlineResources(in: message)
                let stored = try await write { tx -> Bool in
                    guard !deleted.withLock({ $0.contains(message.id) }),
                          let live = try tx.message(id: message.id, accountID: accountID),
                          live.threadID == message.threadId, live.historyID == version,
                          try tx.body(messageID: message.id, accountID: accountID) != nil else { return false }
                    try tx.replaceMIMEResources(resources, messageID: message.id, accountID: accountID)
                    return true
                }
                if stored { rememberReadingCompletion(message.id, version: version) }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Optional pictures can retry on the next explicit open. */ }
        }
    }

    private func rememberReadingCompletion(_ messageID: String, version: Int64) {
        completedReadingVersions[messageID] = version
        completedReadingOrder.removeAll { $0 == messageID }
        completedReadingOrder.append(messageID)
        while completedReadingOrder.count > 512 {
            completedReadingVersions[completedReadingOrder.removeFirst()] = nil
        }
    }
}
