import Foundation
import GmailAPI
import MailStore
import MessageContent

/// One page of conversations from Gmail, in Gmail's order.
public struct GmailResultPage: Sendable, Equatable {
    public let threadIDs: [String]
    /// Nil on the last page.
    public let nextPageToken: String?
}

extension SyncEngine {
    static let resultPageSize = 25

    /// One page of Gmail's results for `query`, with calendar days sent as
    /// epoch seconds in `timeZone`. Conversations the cache lacks are fetched
    /// and stored; every returned conversation is held for a day.
    public func searchGmail(_ query: SearchQuery, timeZone: TimeZone, pageToken: String? = nil) async throws -> GmailResultPage {
        guard query.root != nil else { return GmailResultPage(threadIDs: [], nextPageToken: nil) }
        return try await listAndHold(
            query: query.gmailQuery(timeZone: timeZone), labelIDs: [],
            includeSpamTrash: query.includesSpamAndTrash, pageToken: pageToken
        )
    }

    /// One page of a label's conversations for "Load older conversations",
    /// stored and held like search results.
    public func loadOlder(labelID: String, pageToken: String? = nil) async throws -> GmailResultPage {
        let spamOrTrash = labelID == SystemLabel.spam || labelID == SystemLabel.trash
        return try await listAndHold(query: nil, labelIDs: [labelID], includeSpamTrash: spamOrTrash, pageToken: pageToken)
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
        if isStopped || Task.isCancelled { throw CancellationError() }
        let (updates, gone) = try await fetchThreadMetadata(uncached)
        let found = listed.filter { !gone.contains($0) }

        let deleted = deletedMessageIDs
        let expiresAt = now().addingTimeInterval(CacheHolds.searchLifetime)
        // Messages and holds land together, so no prune runs between them.
        try await write { [updates] tx in
            let live = deleted.withLock { ids in updates.filter { !ids.contains($0.record.id) } }
            let threads = try tx.upsertMessages(live)
            try tx.holdSearchResults(found, until: expiresAt, accountID: accountID)
            try tx.rebuildThreads(threads, accountID: accountID)
        }
        return GmailResultPage(threadIDs: found, nextPageToken: page.nextPageToken)
    }

    /// Metadata for every message in `threadIDs`, plus the conversations Gmail
    /// no longer has. Any other failed part fails the request.
    private func fetchThreadMetadata(
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
