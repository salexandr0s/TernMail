import MailStore

extension SyncEngine {
    /// One bounded batch per normal sync. Historical analytics metadata is
    /// refreshed without pulling evicted message bodies back into the cache.
    func backfillRecipientHeaders() async throws {
        let accountID = accountID
        let ids = try await cache.read { try $0.pendingRecipientHeaderBackfill(accountID: accountID) }
        guard !ids.isEmpty else { return }
        let (updates, missing) = try await fetchMetadata(ids)
        let deleted = deletedMessageIDs
        try await write { tx in
            deleted.withLock { $0.formUnion(missing) }
            let live = deleted.withLock { gone in updates.filter { !gone.contains($0.record.id) } }
            let cached = try tx.cachedMessageIDs(among: live.map(\.record.id), accountID: accountID)
            try tx.upsertAnalyticsMessages(live)
            var threads = try tx.upsertMessages(live.filter { cached.contains($0.record.id) })
            threads.formUnion(try tx.deleteMessages(ids: missing, accountID: accountID))
            try tx.deleteAnalyticsMessages(messageIDs: Array(missing), accountID: accountID)
            try tx.finishRecipientHeaderBackfill(messageIDs: ids, accountID: accountID)
            try tx.rebuildThreads(threads, accountID: accountID)
        }
    }

    /// Folds the addresses of the messages `address-search-v1` left empty,
    /// 500 to a write, yielding after each so other writes run in between.
    /// Address completion folds them as it reads until then, and a failure
    /// leaves the rest for the next launch.
    func foldPendingAddresses() async {
        let accountID = accountID
        var after: Int64 = 0
        while let last = try? await write({ [after] tx in
            try tx.foldPendingAddresses(accountID: accountID, after: after, limit: 500)
        }) {
            after = last
            await Task.yield()
        }
    }
}
