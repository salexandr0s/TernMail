import Foundation
import GmailAPI
import MailStore
import MessageContent

/// One page of conversations from Gmail, in Gmail's order.
public struct GmailResultPage: Sendable, Equatable {
    public let threadIDs: [String]
    /// Nil on the last page.
    public let nextPageToken: String?
    /// Exact matches when the message-mode endpoint was used.
    public let messageIDs: [String]

    public init(threadIDs: [String], nextPageToken: String?, messageIDs: [String] = []) {
        self.threadIDs = threadIDs
        self.nextPageToken = nextPageToken
        self.messageIDs = messageIDs
    }
}

extension SyncEngine {
    static let resultPageSize = 25

    /// One page of Gmail's results for `query`, with calendar days sent as
    /// epoch seconds in `timeZone`. Conversations the cache lacks are fetched
    /// and stored; every returned conversation is held for a day.
    public func searchGmail(_ query: SearchQuery, timeZone: TimeZone, pageToken: String? = nil) async throws -> GmailResultPage {
        guard query.root != nil else { return GmailResultPage(threadIDs: [], nextPageToken: nil) }
        // The user is waiting on the results, so they go ahead of sync and background work.
        return try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await listAndHold(
                query: query.gmailQuery(timeZone: timeZone), labelIDs: [],
                includeSpamTrash: query.includesSpamAndTrash, pageToken: pageToken
            )
        }
    }

    /// Message mode must ask messages.list: threads.list does not identify
    /// which sibling matched a Gmail-only operator.
    public func searchGmailMessages(_ query: SearchQuery, timeZone: TimeZone, pageToken: String? = nil) async throws -> GmailResultPage {
        guard !isStopped, !Task.isCancelled else { throw CancellationError() }
        guard query.root != nil else { return GmailResultPage(threadIDs: [], nextPageToken: nil) }
        return try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await listMessagesAndHold(query, timeZone: timeZone, pageToken: pageToken)
        }
    }

    private func listMessagesAndHold(_ query: SearchQuery, timeZone: TimeZone, pageToken: String?) async throws -> GmailResultPage {
        let page = try await gmail.listMessages(query: query.gmailQuery(timeZone: timeZone), labelIDs: [],
            includeSpamTrash: query.includesSpamAndTrash, pageToken: pageToken, maxResults: Self.resultPageSize)
        var references: [String: String] = [:]
        var ids: [String] = []
        for reference in page.messages ?? [] {
            if let previous = references[reference.id] {
                guard previous == reference.threadId else { throw GmailError.decoding("Search result identity") }
            } else {
                references[reference.id] = reference.threadId
                ids.append(reference.id)
            }
        }
        let (updates, _) = try await fetchMetadata(ids)
        for update in updates {
            guard references[update.record.id] == update.record.threadID else { throw GmailError.decoding("Search result thread identity") }
        }
        let accountID = accountID
        let deleted = deletedMessageIDs
        let expires = now().addingTimeInterval(CacheHolds.searchLifetime)
        let live = try await write { tx -> [CacheTransaction.MessageUpdate] in
            let live = deleted.withLock { gone in updates.filter { !gone.contains($0.record.id) } }
            let threads = try tx.upsertMessages(live)
            try tx.holdSearchResults(Set(live.map(\.record.threadID)), until: expires, accountID: accountID)
            try tx.rebuildThreads(threads, accountID: accountID)
            return live
        }
        let found = Set(live.map(\.record.id))
        var seenThreads = Set<String>()
        return GmailResultPage(threadIDs: live.map(\.record.threadID).filter { seenThreads.insert($0).inserted },
            nextPageToken: page.nextPageToken, messageIDs: ids.filter { found.contains($0) })
    }

    /// One page of a label's conversations for "Load older conversations",
    /// stored and held like search results. `before` skips the newer
    /// conversations the list already shows, which Gmail would otherwise
    /// return first; keep it the same for every page of one listing.
    public func loadOlder(labelID: String, before: Date? = nil, pageToken: String? = nil) async throws -> GmailResultPage {
        let spamOrTrash = labelID == SystemLabel.spam || labelID == SystemLabel.trash
        let query = before.map { "before:\(Int($0.timeIntervalSince1970.rounded(.up)))" }
        return try await GmailRequestBudget.$priority.withValue(.interactive) {
            try await listAndHold(query: query, labelIDs: [labelID], includeSpamTrash: spamOrTrash, pageToken: pageToken)
        }
    }

    /// Conversations an open search or list shows. Releasing expired holds
    /// leaves them alone.
    public nonisolated func setVisibleThreads(_ threadIDs: Set<String>) {
        visibleThreadIDs.withLock { $0 = threadIDs }
    }

    /// Ends expired search holds and drops the conversations nothing else
    /// keeps. Runs after each pass, so what the pass just listed counts.
    func releaseExpiredHolds() async throws {
        let accountID = accountID
        let visible = visibleThreadIDs
        let releasedAt = now()
        try await write { tx in
            let threads = try tx.releaseExpiredHolds(now: releasedAt, keeping: visible.withLock { $0 }, accountID: accountID)
            try tx.rebuildThreads(threads, accountID: accountID)
        }
    }

    private func listAndHold(
        query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?
    ) async throws -> GmailResultPage {
        if isStopped || Task.isCancelled { throw CancellationError() }
        let page = try await gmail.listThreads(
            query: query, labelIDs: labelIDs, includeSpamTrash: includeSpamTrash,
            pageToken: pageToken, maxResults: Self.resultPageSize
        )
        var seen = Set<String>()
        let listed = (page.threads ?? []).map(\.id).filter { seen.insert($0).inserted }
        let accountID = accountID
        let uncached = try await cache.read { tx in
            try listed.filter { try tx.messages(threadID: $0, accountID: accountID).isEmpty }
        }
        let deleted = deletedMessageIDs
        var wanted = uncached
        var fetched = Set<String>()
        var updates: [CacheTransaction.MessageUpdate] = []
        var gone = Set<String>()
        while true {
            if isStopped || Task.isCancelled { throw CancellationError() }
            let (more, missing) = try await fetchThreadMetadata(wanted)
            updates += more
            gone.formUnion(missing)
            fetched.formUnion(wanted)
            let found = listed.filter { !gone.contains($0) }
            let expiresAt = now().addingTimeInterval(CacheHolds.searchLifetime)
            // Messages and holds land together, so no prune runs between them.
            // A release during the fetch may have pruned conversations that
            // were cached when read; those are fetched before anything lands.
            let pruned = try await write { [updates, fetched] tx -> [String] in
                let pruned = try found.filter { try !fetched.contains($0) && tx.messages(threadID: $0, accountID: accountID).isEmpty }
                guard pruned.isEmpty else { return pruned }
                let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
                let threads = try tx.upsertMessages(live)
                try tx.holdSearchResults(found, until: expiresAt, accountID: accountID)
                try tx.rebuildThreads(threads, accountID: accountID)
                return []
            }
            guard !pruned.isEmpty else { return GmailResultPage(threadIDs: found, nextPageToken: page.nextPageToken) }
            wanted = pruned
        }
    }

    /// Metadata for every message in `threadIDs`, plus the conversations Gmail
    /// no longer has. Any other failed part fails the request.
    func fetchThreadMetadata(
        _ threadIDs: [String]
    ) async throws -> (updates: [CacheTransaction.MessageUpdate], missing: Set<String>) {
        guard !threadIDs.isEmpty else { return ([], []) }
        let results = try await gmail.threads(ids: threadIDs, format: .metadata, metadataHeaders: Self.metadataHeaders)
        var updates: [CacheTransaction.MessageUpdate] = []
        var missing = Set<String>()
        for id in threadIDs {
            switch results[id] {
            case .success(let thread)?:
                guard thread.id == id else { throw GmailError.decoding("Thread identity") }
                for message in thread.messages ?? [] {
                    guard message.threadId == id else { throw GmailError.decoding("Message thread identity") }
                    updates.append(try Mapping.message(message, accountID: accountID))
                }
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
}
