import Foundation
import GmailAPI
import GRDB
import Testing
@testable import MailStore
@testable import SyncEngine

@Suite struct RecipientHeaderTests {
    @Test func mappingDistinguishesUnfetchedBccFromAnAbsentHeader() throws {
        let plain = try decode(GmailMessage.self, encodedMessage("plain", thread: "thread"))
        #expect(try Mapping.message(plain, accountID: account).record.bcc == "")
        let json = try encodedMessage("blind", thread: "thread").replacingOccurrences(
            of: "\"headers\": [", with: "\"headers\": [{\"name\":\"Bcc\",\"value\":\"Alex <alex@example.test>\"},")
        let blind = try decode(GmailMessage.self, json)
        #expect(try Mapping.message(blind, accountID: account).record.bcc == "Alex <alex@example.test>")
        #expect(SyncEngine.metadataHeaders.contains("Bcc"))
    }

    @Test func lateBackfillCannotRestoreDeletedAnalyticsAndNotFoundBecomesATombstone() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("deleted", "thread", [SystemLabel.sent])])
        await gmail.add(try decode(GmailMessage.self, encodedMessage("deleted", thread: "thread", labels: [SystemLabel.sent])))
        try await cache.write { tx in
            for id in ["deleted", "gone"] {
                try tx.db.execute(sql: "INSERT INTO recipientHeaderBackfill (accountID,messageID) VALUES (?,?)", arguments: [account, id])
            }
        }
        await gmail.holdNextMetadata()
        let backfill = Task { try await engine.backfillRecipientHeaders() }
        while await !gmail.isHoldingMetadata { await Task.yield() }
        let deleted = await engine.deletedMessageIDs
        deleted.withLock { _ = $0.insert("deleted") }
        try await cache.write { tx in
            _ = try tx.deleteMessages(ids: ["deleted"], accountID: account)
            try tx.deleteAnalyticsMessages(messageIDs: ["deleted"], accountID: account)
        }
        await gmail.releaseMetadata()
        try await backfill.value
        #expect(deleted.withLock { $0.contains("gone") })
        #expect(try await cache.read { try $0.message(id: "deleted", accountID: account) } == nil)
        let snapshot = try await cache.mailAnalytics(query: .init(accountIDs: [account], period: .allTime, now: baseDate))
        #expect(snapshot.totalCount == 0)
    }

    @Test func backfillRefreshesCachedAndEvictedMetadataWithoutRestoringEvictedMail() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("cached", "cached-thread", [SystemLabel.sent])])
        for id in ["cached", "evicted"] {
            let json = try encodedMessage(id, thread: id + "-thread", labels: [SystemLabel.sent])
                .replacingOccurrences(of: "\"headers\": [",
                    with: "\"headers\": [{\"name\":\"Bcc\",\"value\":\"alex@example.test\"},")
            await gmail.add(try decode(GmailMessage.self, json))
        }
        try await cache.write { tx in
            for id in ["cached", "evicted", "gone"] {
                try tx.db.execute(sql: "INSERT INTO recipientHeaderBackfill (accountID,messageID) VALUES (?,?)",
                    arguments: [account, id])
            }
        }
        try await engine.backfillRecipientHeaders()
        #expect(try await cache.read { try $0.message(id: "cached", accountID: account)?.bcc } == "alex@example.test")
        #expect(try await cache.read { try $0.message(id: "evicted", accountID: account) } == nil)
        #expect(try await cache.read { try $0.pendingRecipientHeaderBackfill(accountID: account) }.isEmpty)
        let snapshot = try await cache.mailAnalytics(query: .init(accountIDs: [account],
            contactAddress: "alex@example.test", period: .allTime, now: baseDate, timeZone: .gmt))
        #expect(snapshot.sentCount == 2)
        let requests = await gmail.metadataRequests.count
        try await engine.backfillRecipientHeaders()
        #expect(await gmail.metadataRequests.count == requests)
    }
}
