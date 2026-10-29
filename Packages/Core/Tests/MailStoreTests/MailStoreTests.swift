import Foundation
import GRDB
import Testing
@testable import MailStore

private let account = "acct"

@Suite struct MailCacheTests {
    @Test func pendingArchiveHidesThreadUntilItsRowIsDeleted() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([
                update("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread]),
                update("m2", thread: "t1", labels: [SystemLabel.sent], minutes: 5),
            ])
            try tx.rebuildThreads(["t1"], accountID: account)
        }
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])

        let action = try await cache.write { tx in
            try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: .now, notBefore: .now)
        }
        #expect(action.diff == ["m1": .init(added: [], removed: [SystemLabel.inbox])])
        #expect(try await threadIDs(cache, SystemLabel.inbox).isEmpty)
        #expect(try await threadIDs(cache, SystemLabel.allMail) == ["t1"])
        #expect(try await serverLabels(cache, "m1") == [SystemLabel.inbox, SystemLabel.unread])

        let id = try #require(action.id)
        try await cache.write { tx in try tx.deleteAction(id: id) }
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
    }

    @Test func trashedMessagesListTheirThreadOnlyUnderTrash() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([
                update("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.trash]),
                update("m2", thread: "t2", labels: [SystemLabel.inbox]),
            ])
            try tx.rebuildThreads(["t1", "t2"], accountID: account)
            _ = try tx.enqueue(.trashThreads, accountID: account, threadIDs: ["t2"], add: [SystemLabel.trash], now: .now, notBefore: .now)
        }

        #expect(try await threadIDs(cache, SystemLabel.inbox).isEmpty)
        #expect(try await threadIDs(cache, SystemLabel.allMail).isEmpty)
        #expect(try await threadIDs(cache, SystemLabel.trash) == ["t1", "t2"])
    }

    @Test func olderMetadataDoesNotOverwriteNewer() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([update("m1", thread: "t1", labels: [SystemLabel.inbox], historyID: 200)])
            try tx.upsertMessages([update("m1", thread: "t1", labels: [], historyID: 150)])
        }

        #expect(try await serverLabels(cache, "m1") == [SystemLabel.inbox])
    }

    @Test func resyncCleanupKeepsMessagesThatPendingActionsTarget() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([
                update("m1", thread: "t1", labels: [SystemLabel.inbox]),
                update("m2", thread: "t2", labels: [SystemLabel.inbox]),
                update("m3", thread: "t3", labels: [SystemLabel.inbox]),
            ])
            try tx.rebuildThreads(["t1", "t2", "t3"], accountID: account)
            _ = try tx.enqueue(.modifyMessages, accountID: account, messageIDs: ["m3"], add: [SystemLabel.starred], now: .now, notBefore: .now)

            let affected = try tx.deleteMessages(notIn: ["m1"], accountID: account)
            try tx.rebuildThreads(affected, accountID: account)
        }

        let remaining = try await cache.write { tx in try tx.cachedMessageIDs(accountID: account) }
        #expect(remaining == ["m1", "m3"])
        #expect(try await threadIDs(cache, SystemLabel.inbox).sorted() == ["t1", "t3"])
    }
}

// MARK: Helpers

private func update(
    _ id: String,
    thread: String,
    labels: [String],
    minutes: Double = 0,
    historyID: Int64 = 100
) -> CacheTransaction.MessageUpdate {
    let record = MessageRecord(
        accountID: account, id: id, threadID: thread, historyID: historyID,
        date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60),
        snippet: "", sender: "Sender <s@example.com>", recipients: "r@example.com",
        cc: nil, subject: "Subject", sizeEstimate: 1
    )
    return .init(record: record, labelIDs: labels)
}

private func threadIDs(_ cache: MailCache, _ labelID: String) async throws -> [String] {
    try await cache.writer.read { db in
        try String.fetchAll(db, sql: """
            SELECT threadID FROM threadLabel WHERE accountID = ? AND labelID = ? ORDER BY threadID
            """, arguments: [account, labelID])
    }
}

private func serverLabels(_ cache: MailCache, _ messageID: String) async throws -> Set<String> {
    try await cache.writer.read { db in
        try String.fetchSet(db, sql: """
            SELECT labelID FROM messageLabel WHERE accountID = ? AND messageID = ?
            """, arguments: [account, messageID])
    }
}
