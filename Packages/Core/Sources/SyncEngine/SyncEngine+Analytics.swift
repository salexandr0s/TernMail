import Foundation
import GmailAPI
import MailStore

extension SyncEngine {
    /// Loads one page without opening messages or retaining their bodies. The index
    /// represents a dated enumeration, not an atomic snapshot of Gmail's changing mailbox.
    @discardableResult
    public func loadAnalyticsHistoryPage(restart: Bool = false) async throws -> MailAnalyticsCoverage {
        try checkAnalyticsAccess()
        let accountID = accountID
        let state = try await write { try $0.beginAnalyticsHistory(accountID: accountID, restart: restart) }
        if state.isComplete { return try await cache.read { try $0.analyticsCoverage(accountID: accountID) } }
        do {
            let page = try await gmail.listMessages(query: "-in:spam -in:trash -in:drafts", labelIDs: [],
                includeSpamTrash: false, pageToken: state.nextPageToken, maxResults: 100)
            try checkAnalyticsAccess()
            if let token = page.nextPageToken, token == state.nextPageToken {
                throw GmailError.invalidRequest("History pagination did not advance")
            }
            var references: [String: String] = [:]
            for reference in page.messages ?? [] {
                if let thread = references[reference.id], thread != reference.threadId {
                    throw GmailError.decoding("Analytics message identity")
                }
                references[reference.id] = reference.threadId
            }
            guard references.count <= 100 else { throw GmailError.decoding("Analytics page size") }
            let ids = references.keys.sorted()
            var updates: [CacheTransaction.MessageUpdate] = []
            var missing = Set<String>()
            for offset in stride(from: 0, to: ids.count, by: 25) {
                try checkAnalyticsAccess()
                let fetched = try await fetchMetadata(Array(ids[offset..<min(offset + 25, ids.count)]))
                try checkAnalyticsAccess()
                for update in fetched.updates {
                    guard references[update.record.id] == update.record.threadID else {
                        throw GmailError.decoding("Analytics thread identity")
                    }
                }
                updates += fetched.updates
                missing.formUnion(fetched.missing)
            }
            try checkAnalyticsAccess()
            let deleted = deletedMessageIDs
            let loadedAt = now()
            let savedUpdates = updates
            let savedMissing = missing
            return try await write { tx in
                deleted.withLock { $0.formUnion(savedMissing) }
                let live = deleted.withLock { gone in savedUpdates.filter { !gone.contains($0.record.id) } }
                return try tx.commitAnalyticsHistoryPage(state, updates: live, missing: savedMissing,
                    nextPageToken: page.nextPageToken, loadedAt: loadedAt)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkAnalyticsAccess()
            let expired: Bool
            if case GmailError.http(status: 400, _) = error, state.nextPageToken != nil { expired = true }
            else { expired = false }
            try await write { try $0.failAnalyticsHistory(state, paginationExpired: expired) }
            throw error
        }
    }

    private func checkAnalyticsAccess() throws {
        if isStopped || stopRequested.withLock({ $0 }) || Task.isCancelled { throw CancellationError() }
    }
}
