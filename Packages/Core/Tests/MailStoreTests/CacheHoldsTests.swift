import Foundation
import Testing
@testable import MailStore

private let acct = "acct"
private let now = Date(timeIntervalSince1970: 1_900_000_000)
private let day: TimeInterval = 24 * 60 * 60

@Suite struct CacheHoldsTests {
    @Test func fullSyncPruneKeepsHeldConversations() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [stored("m1", thread: "t1"), stored("m2", thread: "t2")])
        let pruned = try await cache.write { tx in
            try tx.holdSearchResults(["t1"], until: now + CacheHolds.searchLifetime, accountID: acct)
            return try tx.deleteMessages(notIn: [], accountID: acct)
        }
        #expect(pruned == ["t2"])
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: acct) } == ["m1"])
    }

    @Test func expiredHoldsReleaseOnlyConversationsNothingElseKeeps() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, [
            stored("m1", thread: "gone"),
            stored("m2", thread: "inbox", labels: [SystemLabel.inbox]),
            stored("m3", thread: "recent", date: now - 5 * day),
            stored("m4", thread: "queued"),
            stored("m5", thread: "draft"),
            stored("m6", thread: "snoozed"),
            stored("m7", thread: "open"),
            stored("m8", thread: "fresh"),
        ])
        let released = try await cache.write { tx in
            try tx.holdSearchResults(
                ["gone", "inbox", "recent", "queued", "draft", "snoozed", "open"], until: now - 60, accountID: acct
            )
            try tx.holdSearchResults(["fresh"], until: now + 3600, accountID: acct)
            // An older page doesn't shorten the hold.
            try tx.holdSearchResults(["fresh"], until: now - 3600, accountID: acct)
            _ = try tx.enqueue(.modifyThreads, accountID: acct, threadIDs: ["queued"], add: [SystemLabel.starred], now: now, notBefore: now)
            try tx.insertLocalDraft(LocalDraft(
                id: "L1", accountID: acct, kind: .reply, rfcMessageID: "<a@example.com>", sourceMessageID: "m5", now: now
            ))
            try tx.db.execute(
                sql: "INSERT INTO cacheHold (accountID, threadID, reason, wakeAt) VALUES (?, ?, ?, ?)",
                arguments: [acct, "snoozed", CacheHoldReason.snooze.rawValue, now + day]
            )

            let released = try tx.releaseExpiredHolds(now: now, keeping: ["open"], accountID: acct)
            try tx.rebuildThreads(released, accountID: acct)
            return released
        }

        #expect(released == ["gone"])
        let (messages, held, gone) = try await cache.read { tx in
            (try tx.cachedMessageIDs(accountID: acct), try tx.heldThreadIDs(accountID: acct), try tx.thread(id: "gone", accountID: acct))
        }
        #expect(messages == ["m2", "m3", "m4", "m5", "m6", "m7", "m8"])
        // The open search's hold waits for a later pass.
        #expect(held == ["snoozed", "open", "fresh"])
        #expect(gone == nil)
    }

    @Test func deletingAnAccountClearsItsHolds() async throws {
        let cache = try MailCache.inMemory()
        let held = try await cache.write { tx in
            try tx.holdSearchResults(["t1"], until: now, accountID: acct)
            try tx.holdSearchResults(["t1"], until: now, accountID: "other")
            try tx.deleteAccountData(accountID: acct)
            return (try tx.heldThreadIDs(accountID: acct), try tx.heldThreadIDs(accountID: "other"))
        }
        #expect(held.0.isEmpty)
        #expect(held.1 == ["t1"])
    }
}

// MARK: Helpers

/// An archived message from 90 days before `now`, which full sync wouldn't list.
private func stored(_ id: String, thread: String, labels: [String] = [], date: Date = now - 90 * day) -> CacheTransaction.MessageUpdate {
    let record = MessageRecord(
        accountID: acct, id: id, threadID: thread, historyID: 100, date: date,
        snippet: "", sender: "Sender <s@example.com>", recipients: "r@example.com",
        cc: nil, subject: "Subject", sizeEstimate: 1
    )
    return .init(record: record, labelIDs: labels)
}

private func seed(_ cache: MailCache, _ updates: [CacheTransaction.MessageUpdate]) async throws {
    try await cache.write { tx in
        try tx.rebuildThreads(tx.upsertMessages(updates), accountID: acct)
    }
}
