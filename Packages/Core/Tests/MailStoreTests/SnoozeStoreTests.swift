import Foundation
import Testing
@testable import MailStore

private let acct = "acct"
private let other = "other"
private let now = Date(timeIntervalSince1970: 1_900_000_000)
private let hour: TimeInterval = 60 * 60

@Suite struct SnoozeStoreTests {
    @Test func aWokenConversationSortsByItsWakeTimeUntilItLeavesTheInbox() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, acct, [("m1", "t1", now - 48 * hour), ("m2", "t2", now - hour)])
        #expect(try await inbox(cache) == ["t2", "t1"])

        try await cache.write { tx in try tx.recordWake(threadID: "t1", at: now, accountID: acct) }
        #expect(try await inbox(cache) == ["t1", "t2"])
        #expect(try await first(cache.wokenThreadIDs(accountID: acct)) == ["t1"])

        // Archived, then back: it sorts by its own date again.
        let archive = try #require(try await cache.write { tx in
            try tx.enqueue(.modifyThreads, accountID: acct, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: now, notBefore: now)
        })
        #expect(try await first(cache.wokenThreadIDs(accountID: acct)).isEmpty)
        try await cache.write { tx in try tx.deleteAction(id: try #require(archive.id)) }
        #expect(try await inbox(cache) == ["t2", "t1"])
    }

    @Test func snoozedConversationsListSoonestFirstForTheirAccountOnly() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, acct, [("m1", "t1", now), ("m2", "t2", now), ("m3", "t3", now)])
        try await seed(cache, other, [("m1", "t1", now)])
        try await cache.write { tx in
            try tx.holdSnooze(threadID: "t1", until: now + 2 * hour, accountID: acct)
            try tx.holdSnooze(threadID: "t2", until: now + 3 * hour, accountID: acct)
            try tx.holdSnooze(threadID: "t1", until: now + hour, accountID: other)
            // Snoozing again moves the time.
            try tx.holdSnooze(threadID: "t2", until: now + hour, accountID: acct)
            try tx.recordWake(threadID: "t3", at: now, accountID: acct)
        }
        let snoozed = try await first(cache.snoozedThreads(accountID: acct))
        #expect(snoozed.map(\.id) == ["t2", "t1"])
        #expect(snoozed.map(\.wakeAt) == [now + hour, now + 2 * hour])

        try await cache.write { tx in
            try tx.releaseSnooze(threadID: "t2", accountID: acct)
            try tx.deleteAccountData(accountID: other)
        }
        #expect(try await cache.read { tx in try tx.snoozeHolds(accountID: acct) } == ["t1": now + 2 * hour])
        try await cache.write { tx in try tx.deleteAccountData(accountID: acct) }
        #expect(try await first(cache.snoozedThreads(accountID: acct)).isEmpty)
        #expect(try await first(cache.wokenThreadIDs(accountID: acct)).isEmpty)
    }

    @Test func snoozeRecordsGoWithTheirAccount() async throws {
        let store = try AccountStore.inMemory()
        for id in [acct, other] {
            try await store.save(AccountRecord(id: id, email: "\(id)@example.com", displayName: nil, grantedScopes: [], addedAt: now))
            try await store.saveSnooze(SnoozeRecord(accountID: id, threadID: "t1", wakeAt: now + hour, createdAt: now))
        }
        try await store.saveSnooze(SnoozeRecord(accountID: acct, threadID: "t2", wakeAt: now + 2 * hour, createdAt: now))
        // Saving the account again, as a sign-in does, keeps its snoozes.
        try await store.save(AccountRecord(id: acct, email: "acct@example.com", displayName: "A", grantedScopes: [], addedAt: now))
        try await store.deleteSnooze(accountID: acct, threadID: "t1")
        #expect(try await store.snoozes(accountID: acct).map(\.threadID) == ["t2"])

        try await store.deleteAccount(id: acct)
        #expect(try await store.snoozes(accountID: acct).isEmpty)
        #expect(try await store.snoozes(accountID: other).map(\.threadID) == ["t1"])
    }
}

// MARK: Helpers

private func seed(_ cache: MailCache, _ accountID: String, _ messages: [(id: String, thread: String, date: Date)]) async throws {
    let updates = messages.map { message in
        CacheTransaction.MessageUpdate(
            record: MessageRecord(
                accountID: accountID, id: message.id, threadID: message.thread, historyID: 100, date: message.date,
                snippet: "", sender: "A <a@example.com>", recipients: "", cc: nil, subject: "Subject", sizeEstimate: 0
            ),
            labelIDs: [SystemLabel.inbox]
        )
    }
    try await cache.write { tx in try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: accountID) }
}

private func inbox(_ cache: MailCache) async throws -> [String] {
    try await first(cache.threads(accountID: acct, labelID: SystemLabel.inbox, limit: 10)).map(\.id)
}

private func first<T>(_ stream: AsyncThrowingStream<T, any Error>) async throws -> T {
    for try await value in stream { return value }
    throw CancellationError()
}
