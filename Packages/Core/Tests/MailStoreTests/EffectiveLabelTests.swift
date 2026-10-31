import Foundation
import GRDB
import Testing
@testable import MailStore

private let account = "acct"
private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// The reader and the list read the effective labels `rebuildThreads` keeps in
/// a table, where they used to overlay the queue on every fetch.
@Suite struct EffectiveLabelTests {
    @Test func storedLabelsFollowTheOverlayThroughEachQueueChange() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.rebuildThreads(try tx.upsertMessages([
                incoming("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread]),
                incoming("m2", thread: "t1", labels: [SystemLabel.inbox, "Label_1"], minutes: 5),
                incoming("m3", thread: "t2", labels: [SystemLabel.inbox, "Label_1"], minutes: 10),
            ]), accountID: account)
        }
        try await expectStoredLabelsMatchTheOverlay(cache)

        // An archive still to go out covers a message that arrives meanwhile.
        let archive = try await cache.write { tx in
            let archive = try #require(try tx.enqueue(
                .modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: now, notBefore: now
            ))
            try tx.rebuildThreads(try tx.upsertMessages([
                incoming("m4", thread: "t1", labels: [SystemLabel.inbox], minutes: 15),
            ]), accountID: account)
            return archive
        }
        try await expectStoredLabelsMatchTheOverlay(cache)
        #expect(try await stored(cache, "m4") == [])

        // Sent, it covers only the messages it named, so the newcomer is back
        // in the Inbox with no other write.
        try await cache.write { tx in
            var sent = archive
            sent.state = .sent
            sent.sentAt = now
            try tx.updateAction(sent)
        }
        try await expectStoredLabelsMatchTheOverlay(cache)
        #expect(try await stored(cache, "m4") == [SystemLabel.inbox])

        // A label delete Gmail refuses comes off on Retry.
        let delete = try await cache.write { tx in
            try tx.enqueueLabelChange(.deleteLabel, labelID: "Label_1", change: .init(), accountID: account, now: now, notBefore: now)
        }
        #expect(try await stored(cache, "m3") == [SystemLabel.inbox])
        try await cache.write { tx in try tx.retainFailedAction(delete, message: "refused") }
        try await expectStoredLabelsMatchTheOverlay(cache)
        #expect(try await stored(cache, "m3") == [SystemLabel.inbox, "Label_1"])
        try await cache.write { tx in _ = try tx.retryFailedAction(id: try #require(delete.id), accountID: account, now: now) }
        try await expectStoredLabelsMatchTheOverlay(cache)
        #expect(try await stored(cache, "m3") == [SystemLabel.inbox])

        // Undone mid-send, a change shows nothing.
        let star = try await cache.write { tx in
            try #require(try tx.enqueue(
                .modifyMessages, accountID: account, messageIDs: ["m3"], add: [SystemLabel.starred], now: now, notBefore: now
            ))
        }
        #expect(try await stored(cache, "m3") == [SystemLabel.inbox, SystemLabel.starred])
        try await cache.write { tx in
            var undone = star
            undone.state = .undone
            try tx.updateAction(undone)
        }
        try await expectStoredLabelsMatchTheOverlay(cache)
        #expect(try await stored(cache, "m3") == [SystemLabel.inbox])
    }

    @Test func aSendThatKeepsTheLabelsWakesNoReaderOrList() async throws {
        let cache = try MailCache.inMemory()
        let archive = try await cache.write { tx in
            try tx.rebuildThreads(try tx.upsertMessages([
                incoming("m1", thread: "t1", labels: [SystemLabel.inbox]),
                incoming("m2", thread: "t1", labels: [SystemLabel.inbox], minutes: 5),
            ]), accountID: account)
            return try #require(try tx.enqueue(
                .modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: now, notBefore: now
            ))
        }

        // Neither observation reads the queue, only the labels it produces.
        let stateChange = DatabaseEventKind.update(tableName: "pendingAction", columnNames: ["state", "sentAt", "confirmedHistoryID"])
        let reader = try await trackedRegion(cache) { tx in try tx.threadDetail(threadID: "t1", accountID: account) }
        let list = try await trackedRegion(cache) { tx in try tx.messageListEntries(threadsByAccount: [account: ["t1"]]) }
        for region in [reader, list] {
            #expect(!region.isModified(byEventsOfKind: stateChange))
            #expect(region.isModified(byEventsOfKind: .insert(tableName: "effectiveLabel")))
        }

        // Sending writes the queue row and nothing the observations read.
        let changedRows = try await cache.write { tx -> Int in
            var sent = archive
            sent.state = .sent
            sent.sentAt = now
            sent.confirmedHistoryID = 150
            let before = tx.db.totalChangesCount
            try tx.updateAction(sent)
            return tx.db.totalChangesCount - before
        }
        #expect(changedRows == 1)
    }

    @Test func anOlderCacheGetsItsPendingChangesInTheTable() throws {
        let queue = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(queue, upTo: "actions-v2")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO message (accountID, id, threadID, historyID, date, snippet, sender, recipients, subject, sizeEstimate)
                VALUES ('acct', 'm1', 't1', 1, '2026-01-01 10:00:00.000', '', '', '', '', 1),
                       ('acct', 'm2', 't2', 1, '2026-01-02 10:00:00.000', '', '', '', '', 1);
                INSERT INTO messageLabel (accountID, messageID, labelID)
                VALUES ('acct', 'm1', 'INBOX'), ('acct', 'm1', 'UNREAD'), ('acct', 'm2', 'INBOX');
                """)
            var archive = PendingAction(
                id: nil, accountID: account, kind: .modifyThreads,
                threadIDs: ["t1"], messageIDs: [], addLabelIDs: [], removeLabelIDs: [SystemLabel.inbox],
                diff: ["m1": .init(added: [], removed: [SystemLabel.inbox])],
                state: .queued, attempts: 0, lastError: nil, createdAt: now, notBefore: now, sentAt: nil
            )
            try archive.insert(db)
        }

        _ = try MailCache(writer: queue)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT messageID, labelID FROM effectiveLabel ORDER BY messageID, labelID")
                .map { row -> String in
                    let messageID: String = row["messageID"]
                    let labelID: String = row["labelID"]
                    return messageID + " " + labelID
                }
        }
        #expect(rows == ["m1 UNREAD", "m2 INBOX"])
    }
}

/// Every conversation's stored labels equal the overlay computed afresh from
/// server labels and the queue, as readers used to compute it.
private func expectStoredLabelsMatchTheOverlay(
    _ cache: MailCache, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let (stored, computed) = try await cache.read { tx in
        let actions = try tx.pendingActions(accountID: account)
        let threads = try String.fetchSet(tx.db, sql: "SELECT threadID FROM message WHERE accountID = ?", arguments: [account])
        var stored: [String: Set<String>] = [:]
        var computed: [String: Set<String>] = [:]
        for thread in threads {
            stored.merge(try tx.storedEffectiveLabels(threadID: thread, accountID: account)) { first, _ in first }
            computed.merge(try tx.effectiveLabels(threadID: thread, accountID: account, actions: actions)) { first, _ in first }
        }
        return (stored, computed)
    }
    #expect(stored == computed, sourceLocation: sourceLocation)
}

private func stored(_ cache: MailCache, _ messageID: String) async throws -> Set<String> {
    try await cache.read { tx in
        try String.fetchSet(
            tx.db, sql: "SELECT labelID FROM effectiveLabel WHERE accountID = ? AND messageID = ?", arguments: [account, messageID]
        )
    }
}

/// The region an observation of `fetch` tracks, which decides what wakes it.
private func trackedRegion<T: Sendable>(
    _ cache: MailCache, _ fetch: @escaping @Sendable (CacheTransaction) throws -> T
) async throws -> DatabaseRegion {
    let (regions, continuation) = AsyncStream.makeStream(of: DatabaseRegion.self)
    let observation = ValueObservation
        .tracking { db in try fetch(CacheTransaction(db: db)) }
        .handleEvents(willTrackRegion: { continuation.yield($0) })
    for try await _ in observation.values(in: cache.writer) { break }
    continuation.finish()
    var tracked = DatabaseRegion()
    for await region in regions { tracked.formUnion(region) }
    return tracked
}

private func incoming(_ id: String, thread: String, labels: [String], minutes: Double = 0) -> CacheTransaction.MessageUpdate {
    CacheTransaction.MessageUpdate(
        record: MessageRecord(
            accountID: account, id: id, threadID: thread, historyID: 100,
            date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60),
            snippet: "Snippet", sender: "Sender <s@example.com>", recipients: "r@example.com",
            cc: nil, subject: "Subject", sizeEstimate: 1
        ),
        labelIDs: labels
    )
}
