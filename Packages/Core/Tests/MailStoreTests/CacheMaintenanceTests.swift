import Foundation
import GRDB
import MessageContent
import Testing
@testable import MailStore

@Suite struct CacheMaintenanceTests {
    private let date = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func resetRechecksDraftAndFailedIntentBeforeRemovingAnyContent() async throws {
        let cache = try MailCache.inMemory()
        try await seed(cache, id: "m", thread: "t")
        #expect(try await cache.cacheResetReadiness().canReset)
        let draft = LocalDraft(id: "draft", accountID: "a", kind: .new, rfcMessageID: "<draft@example.test>", now: date)
        try await cache.write { try $0.insertLocalDraft(draft) }
        await #expect(throws: CacheMaintenanceError.self) { try await cache.resetDisposableCache() }
        #expect(try await cache.read { try $0.body(messageID: "m", accountID: "a") } != nil)
        try await cache.write { tx in _ = try LocalDraft.deleteOne(tx.db, key: "draft") }
        let row = try #require(try await cache.write { tx in
            try tx.enqueue(.modifyMessages, accountID: "a", messageIDs: ["m"], add: [SystemLabel.starred], now: date, notBefore: date)
        })
        #expect(try await cache.cacheResetReadiness().activeActionCount == 1)
        try await cache.write { tx in
            var failed = row
            failed.state = .failed
            failed.lastError = "Rejected"
            try tx.updateAction(failed)
        }
        let readiness = try await cache.cacheResetReadiness()
        #expect(readiness.activeActionCount == 0 && readiness.failedActionCount == 1 && !readiness.canReset)
        await #expect(throws: CacheMaintenanceError.self) { try await cache.resetDisposableCache() }
        #expect(try await cache.read { try $0.message(id: "m", accountID: "a") } != nil)
        let rowID = try #require(row.id)
        try await cache.write { try $0.deleteAction(id: rowID) }
        try await cache.resetDisposableCache()
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: "a") }.isEmpty)
        #expect(try await cache.read { try Int.fetchOne($0.db, sql: "SELECT COUNT(*) FROM messageText") } == 0)
        #expect(try await cache.disposableContentUsage().bodyBytes == 0)
        try await cache.compactDisposableCache()
        try await seed(cache, id: "again", thread: "again")
        #expect(try await cache.read { try $0.body(messageID: "again", accountID: "a") } != nil)
    }

    @Test func evictionRechecksNewHoldsAndProtectsFailedDraftAndAccountBoundaries() async throws {
        let cache = try MailCache.inMemory()
        for id in ["free", "held", "failed", "draft", "recent", "inbox"] {
            try await seed(cache, id: id, thread: id, recent: id == "recent", inbox: id == "inbox")
        }
        try await seed(cache, id: "free", thread: "free", account: "b")
        try await cache.write { tx in
            try tx.holdSearchResults(["held"], until: date.addingTimeInterval(3600), accountID: "a")
            var failed = try #require(try tx.enqueue(.modifyMessages, accountID: "a", messageIDs: ["failed"], add: [SystemLabel.starred], now: date, notBefore: date))
            failed.state = .failed
            try tx.updateAction(failed)
            try tx.insertLocalDraft(LocalDraft(id: "draft", accountID: "a", kind: .reply, rfcMessageID: "<draft@example.test>",
                threadID: "draft", sourceMessageID: "draft", now: date))
            try tx.markThreadOpened(threadID: "free", accountID: "a", at: date.addingTimeInterval(-60))
            try tx.markThreadOpened(threadID: "free", accountID: "a", at: date.addingTimeInterval(-120))
        }
        let other = CacheThreadReference(accountID: "b", threadID: "free")
        let keeping: Set<CacheThreadReference> = [other]
        let candidates = try await cache.evictionCandidates(keeping: keeping, now: date)
        #expect(Set(candidates.map(\.thread.threadID)) == ["free", "recent", "inbox"])
        #expect(candidates.first { $0.thread.threadID == "free" }?.lastOpenedAt == date.addingTimeInterval(-60))
        #expect(candidates.filter(\.canEvictMetadata).map(\.thread.threadID) == ["free"])
        let free = CacheThreadReference(accountID: "a", threadID: "free")
        try await cache.write { try $0.holdSearchResults(["free"], until: date.addingTimeInterval(3600), accountID: "a") }
        #expect(try await cache.evictContent(for: [free], keeping: keeping, now: date).evictedThreads.isEmpty)
        try await cache.write { try $0.db.execute(sql: "DELETE FROM cacheHold WHERE accountID='a' AND threadID='free'") }
        let removed = try await cache.evictContent(for: [free], keeping: keeping, now: date)
        #expect(removed.evictedThreads == [free])
        #expect(removed.releasedContentBytes > 0)
        #expect(try await cache.read { try $0.body(messageID: "free", accountID: "a") } == nil)
        #expect(try await cache.read { try $0.body(messageID: "free", accountID: "b") } != nil)
        let metadata = try await cache.evictMetadata(for: candidates.map(\.thread), keeping: keeping, now: date)
        #expect(metadata.deletedMessageCount == 1)
        #expect(try await cache.read { try $0.message(id: "free", accountID: "a") } == nil)
        for id in ["held", "failed", "draft", "recent", "inbox"] {
            #expect(try await cache.read { try $0.message(id: id, accountID: "a") } != nil)
        }
    }

    @Test func convergedMessageSnoozesRecheckAndProtectOnlyTheirAccount() async throws {
        let cache = try MailCache.inMemory()
        for account in ["a", "b"] { try await seed(cache, id: "m", thread: "t", account: account) }
        let held = CacheThreadReference(accountID: "a", threadID: "t")
        let other = CacheThreadReference(accountID: "b", threadID: "t")
        let staleCandidates = try await cache.evictionCandidates(keeping: [], now: date)
        #expect(Set(staleCandidates.map(\.thread)) == [held, other])
        try await cache.write { tx in
            try tx.holdMessageSnooze(.init(accountID: "a", messageID: "m", threadID: "t",
                wakeAt: date.addingTimeInterval(3600), createdAt: date))
        }
        // The archive already converged: no queue row remains to provide a second hold.
        #expect(try await cache.cacheResetReadiness().canReset)
        let candidates = try await cache.evictionCandidates(keeping: [], now: date)
        #expect(candidates.map(\.thread) == [other])
        let content = try await cache.evictContent(for: staleCandidates.map(\.thread), keeping: [], now: date)
        #expect(content.evictedThreads == [other])
        #expect(try await cache.read { try $0.body(messageID: "m", accountID: "a") } != nil)
        let metadata = try await cache.evictMetadata(for: staleCandidates.map(\.thread), keeping: [], now: date)
        #expect(metadata.evictedThreads == [other])
        #expect(try await cache.read { try $0.messageSnoozeHolds(accountID: "a").count } == 1)
        try await cache.write { tx in _ = try tx.releaseMessageSnooze(messageID: "m", accountID: "a") }
        #expect(try await cache.evictMetadata(for: [held], keeping: [], now: date).evictedThreads == [held])
    }

    @Test func newestOrganizerInvitationMetadataSurvivesEvictionPruneAndHoldExpiry() async throws {
        let cache = try MailCache.inMemory()
        let uid = "event@example.test"
        var bundle = try invitation(uid: "bundle@example.test", method: "PUBLISH", sequence: 0)
        bundle.additionalEvents = [try invitation(uid: uid, sequence: 3, recurrence: "20310717T140000Z")]
        let versions = [
            MessageCalendarRecord(accountID: "a", messageID: "original", invitation: try invitation(uid: uid, sequence: 0)),
            .init(accountID: "a", messageID: "stale", invitation: try invitation(uid: uid, sequence: 1, stamp: "20310109T120000Z")),
            .init(accountID: "a", messageID: "early-cancel", invitation: try invitation(uid: uid, method: "CANCEL", sequence: 2)),
            .init(accountID: "a", messageID: "latest-cancel", invitation: try invitation(uid: uid, method: "CANCEL", sequence: 2, stamp: "20310102T120000Z")),
            .init(accountID: "a", messageID: "tie", invitation: try invitation(uid: uid, method: "PUBLISH", sequence: 2, stamp: "20310102T120000Z")),
            .init(accountID: "a", messageID: "reply", invitation: try invitation(uid: uid, method: "REPLY", sequence: 99)),
            .init(accountID: "a", messageID: "exception", invitation: try invitation(uid: uid, sequence: 0, recurrence: "20310716T140000Z")),
            .init(accountID: "a", messageID: "exception-old", invitation: try invitation(uid: uid, sequence: 1, recurrence: "20310717T140000Z")),
            .init(accountID: "a", messageID: "bundle", invitation: bundle),
            .init(accountID: "b", messageID: "foreign", invitation: try invitation(uid: uid, sequence: 0)),
        ]
        for record in versions { try await seed(cache, id: record.messageID, thread: record.messageID, account: record.accountID) }
        try await cache.write { tx in for record in versions { try tx.saveMessageCalendar(record) } }
        let visible: Set<CacheThreadReference> = [.init(accountID: "a", threadID: "original")]
        let candidates = try await cache.evictionCandidates(keeping: visible, now: date)
        let metadataKept = Set(candidates.filter { !$0.canEvictMetadata }.map(\.thread))
        #expect(metadataKept == [
            .init(accountID: "a", threadID: "latest-cancel"), .init(accountID: "a", threadID: "tie"),
            .init(accountID: "a", threadID: "exception"), .init(accountID: "a", threadID: "bundle"),
            .init(accountID: "b", threadID: "foreign"),
        ])
        let latest = CacheThreadReference(accountID: "a", threadID: "latest-cancel")
        #expect(try await cache.evictContent(for: [latest], keeping: visible, now: date).evictedThreads == [latest])
        #expect(try await cache.read { try $0.body(messageID: "latest-cancel", accountID: "a") } == nil)
        #expect(try await cache.read { try $0.messageCalendar(messageID: "latest-cancel", accountID: "a") } != nil)
        try await cache.write { tx in
            try tx.holdSearchResults(["latest-cancel"], until: date.addingTimeInterval(-60), accountID: "a")
            let removed = try tx.releaseExpiredHolds(now: date, keeping: ["original"], accountID: "a")
            #expect(removed.isEmpty)
        }
        let metadata = try await cache.evictMetadata(for: candidates.map(\.thread), keeping: visible, now: date)
        #expect(metadata.deletedMessageCount == 4)
        try await cache.write { tx in
            _ = try tx.deleteMessages(notIn: ["original"], accountID: "a")
            _ = try tx.deleteMessages(notIn: [], accountID: "b")
        }
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: "a") } == ["original", "latest-cancel", "tie", "exception", "bundle"])
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: "b") } == ["foreign"])
        // A confirmed remote deletion and an explicit reset still remove retained metadata.
        try await cache.write { tx in _ = try tx.deleteMessages(ids: ["latest-cancel"], accountID: "a") }
        #expect(try await cache.read { try $0.messageCalendar(messageID: "latest-cancel", accountID: "a") } == nil)
        try await cache.resetDisposableCache()
        #expect(try await cache.read { try $0.calendarInvitations(accountID: "a").isEmpty })
    }

    private func invitation(uid: String, method: String = "REQUEST", sequence: Int, stamp: String = "20310101T120000Z", recurrence: String? = nil) throws -> Invitation {
        let recurrenceLine = recurrence.map { "RECURRENCE-ID:\($0)\r\n" } ?? ""
        return try Invitation(data: Data(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:\(method)\r\n" +
            "BEGIN:VEVENT\r\nUID:\(uid)\r\nSEQUENCE:\(sequence)\r\nDTSTAMP:\(stamp)\r\n" +
            recurrenceLine + "DTSTART:20310715T140000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n").utf8))
    }

    private func seed(_ cache: MailCache, id: String, thread: String, account: String = "a", recent: Bool = false, inbox: Bool = false) async throws {
        let timestamp = recent ? date : date.addingTimeInterval(-60 * 86400)
        let message = MessageRecord(accountID: account, id: id, threadID: thread, historyID: 1, date: timestamp,
            snippet: "", sender: "sender@example.test", recipients: "me@example.test", cc: nil, subject: "Mail", sizeEstimate: 1)
        try await cache.write { tx in
            try tx.upsertMessages([.init(record: message, labelIDs: inbox ? [SystemLabel.inbox] : [])])
            try tx.rebuildThreads([thread], accountID: account)
            try tx.saveBodies([.init(accountID: account, messageID: id, html: "<b>Resource</b>", plainText: "Resource", fetchedAt: date)])
        }
    }
}
