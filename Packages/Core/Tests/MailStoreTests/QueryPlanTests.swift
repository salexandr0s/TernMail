import Foundation
import GRDB
import Testing
@testable import MailStore

/// The thread list has to come straight off `threadLabel_list`, for one
/// account or several, with no sort step over the whole label.
@Suite struct QueryPlanTests {
    @Test(arguments: [1, 3])
    func theListReadsTheIndexWithoutSorting(accounts: Int) async throws {
        let (cache, accountIDs) = try await SyntheticMailbox.make(.init(accounts: accounts, threads: 40))
        let steps: [String] = try await cache.read { tx in
            try Row.fetchAll(
                tx.db,
                sql: "EXPLAIN QUERY PLAN " + ThreadListQuery.sql(accountCount: accounts),
                arguments: ThreadListQuery.arguments(accountIDs: accountIDs, labelID: SystemLabel.inbox, limit: 50)
            ).map { $0["detail"] }
        }
        let labelScans = steps.filter { $0.contains("threadLabel") }
        #expect(labelScans.count == accounts)
        #expect(labelScans.allSatisfy { $0.contains("USING COVERING INDEX threadLabel_list") })
        #expect(!steps.contains { $0.contains("TEMP B-TREE") }, "\(steps)")
    }

    /// `message_date` would serve the order and scan the account; the thread
    /// index has to win, and it does once it covers the order as well.
    @Test func aConversationsMessagesComeOffTheThreadIndex() async throws {
        let (cache, accountIDs) = try await SyntheticMailbox.make(.init(threads: 40))
        let accountID = try #require(accountIDs.first)
        let steps: [String] = try await cache.read { tx in
            // The request `messages(threadID:accountID:)` builds.
            let request = MessageRecord
                .filter(Column("accountID") == accountID && Column("threadID") == "t0-3")
                .order(Column("date"), Column("id"))
            let prepared = try request.makePreparedRequest(tx.db)
            return try Row.fetchAll(tx.db, sql: "EXPLAIN QUERY PLAN " + prepared.statement.sql, arguments: prepared.statement.arguments)
                .map { $0["detail"] }
        }
        #expect(steps == ["SEARCH message USING INDEX message_thread (accountID=? AND threadID=?)"])
    }

    @Test func aCombinedListIsTheAccountsListsMerged() async throws {
        let (cache, accountIDs) = try await SyntheticMailbox.make(.init(accounts: 3, threads: 60, spacing: 30))
        var expected: [ThreadRecord] = []
        for accountID in accountIDs {
            expected += try await SyntheticMailbox.currentThreads(in: cache, accountIDs: [accountID], labelID: SystemLabel.inbox)
        }
        expected.sort { a, b in
            if a.lastDate != b.lastDate { return a.lastDate > b.lastDate }
            if a.id != b.id { return a.id < b.id }
            return a.accountID < b.accountID
        }
        let combined = try await SyntheticMailbox.currentThreads(
            in: cache, accountIDs: accountIDs.reversed(), labelID: SystemLabel.inbox, limit: 50
        )
        #expect(combined.count == 50)
        #expect(combined == Array(expected.prefix(50)))
    }

    @Test func aWokenConversationKeepsItsPlaceThroughRebuilds() async throws {
        let (cache, accountIDs) = try await SyntheticMailbox.make(.init(threads: 5))
        let accountID = try #require(accountIDs.first)
        let inbox = try await SyntheticMailbox.currentThreads(in: cache, accountIDs: [accountID], labelID: SystemLabel.inbox)
        let oldest = try #require(inbox.last)
        let wokeAt = try #require(inbox.first).lastDate.addingTimeInterval(60)

        try await cache.write { tx in try tx.recordWake(threadID: oldest.id, at: wokeAt, accountID: accountID) }
        #expect(try await SyntheticMailbox.currentThreads(in: cache, accountIDs: [accountID], labelID: SystemLabel.inbox).first?.id == oldest.id)

        // A later pass rebuilds the conversation; the wake still sorts it.
        try await cache.write { tx in try tx.rebuildThreads([oldest.id], accountID: accountID) }
        #expect(try await SyntheticMailbox.currentThreads(in: cache, accountIDs: [accountID], labelID: SystemLabel.inbox).first?.id == oldest.id)

        // Once it leaves the Inbox the wake is forgotten, so coming back puts it at its own date.
        _ = try await cache.write { tx in
            try tx.enqueue(.modifyThreads, accountID: accountID, threadIDs: [oldest.id], remove: [SystemLabel.inbox], now: .now, notBefore: .now)
        }
        #expect(try await cache.read { tx in try tx.wakeTime(threadID: oldest.id, accountID: accountID) } == nil)
        try await cache.write { tx in
            for action in try tx.pendingActions(accountID: accountID) {
                try tx.deleteAction(id: try #require(action.id))
            }
        }
        #expect(try await SyntheticMailbox.currentThreads(in: cache, accountIDs: [accountID], labelID: SystemLabel.inbox).last?.id == oldest.id)
    }

    @Test func theMigrationBackfillsListDatesFromWakes() throws {
        let queue = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(queue, upTo: "attachment-classification-v2")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO thread (accountID, id, lastDate, subject, snippet, participants, messageCount, isUnread, isStarred)
                VALUES ('a', 't1', '2026-01-01 10:00:00.000', '', '', '', 1, 0, 0),
                       ('a', 't2', '2026-01-02 10:00:00.000', '', '', '', 1, 0, 0);
                INSERT INTO threadLabel (accountID, threadID, labelID, lastDate)
                VALUES ('a', 't1', 'INBOX', '2026-01-01 10:00:00.000'),
                       ('a', 't2', 'INBOX', '2026-01-02 10:00:00.000');
                INSERT INTO wokenThread (accountID, threadID, wokeAt) VALUES ('a', 't1', '2026-01-03 10:00:00.000');
                """)
        }
        try Schema.cacheMigrator.migrate(queue)
        let listDates = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT threadID, listDate FROM threadLabel")
                .reduce(into: [String: String]()) { $0[$1["threadID"]] = $1["listDate"] }
        }
        #expect(listDates == ["t1": "2026-01-03 10:00:00.000", "t2": "2026-01-02 10:00:00.000"])
    }
}
