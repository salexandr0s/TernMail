import Foundation
import GRDB
import MessageContent
import os
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

    @Test func evictionChecksOnlyTheThreadsItIsGiven() async throws {
        // A trim pass lists candidates once and evicts them in batches, so a
        // batch must not grow with the cache by listing every thread again.
        let small = try await evictionStatements(cachedThreads: 2)
        let large = try await evictionStatements(cachedThreads: 30)
        #expect(small == large)
    }

    @Test func evictionSkipsThreadsThatGainedADraftOrAChangeAfterTheyWereListed() async throws {
        let cache = try MailCache.inMemory()
        for id in ["forwarded", "changed", "free"] { try await seed(cache, id: id, thread: id) }
        let listed = try await cache.evictionCandidates(keeping: [], now: date).map(\.thread)
        #expect(Set(listed.map(\.threadID)) == ["forwarded", "changed", "free"])
        try await cache.write { tx in
            try tx.insertLocalDraft(LocalDraft(id: "forward", accountID: "a", kind: .forward, rfcMessageID: "<forward@example.test>",
                sourceMessageID: "forwarded", now: date))
            _ = try tx.enqueue(.modifyMessages, accountID: "a", messageIDs: ["changed"], add: [SystemLabel.starred], now: date, notBefore: date)
        }
        let free = CacheThreadReference(accountID: "a", threadID: "free")
        #expect(try await cache.evictContent(for: listed, keeping: [], now: date).evictedThreads == [free])
        #expect(try await cache.evictMetadata(for: listed, keeping: [], now: date).evictedThreads == [free])
        for id in ["forwarded", "changed"] {
            #expect(try await cache.read { try $0.body(messageID: id, accountID: "a") } != nil)
        }
    }

    @Test func storedBodySizesFollowEverySaveAndRemoval() async throws {
        let cache = try MailCache.inMemory()
        let html = "<p>Γιώργος</p>", text = "Élodie 👋"
        try await seed(cache, id: "m", thread: "t", html: html, plainText: text)
        try await seed(cache, id: "other", thread: "other")
        #expect(try await bodySizes(cache)["m"] == html.utf8.count + text.utf8.count)
        let thread = CacheThreadReference(accountID: "a", threadID: "t")
        let listed = try await cache.evictionCandidates(keeping: [], now: date).first { $0.thread == thread }
        #expect(listed?.disposableBytes == Int64(html.utf8.count + text.utf8.count))
        try await cache.write { try $0.saveBodies([.init(accountID: "a", messageID: "m", html: nil, plainText: text + text, fetchedAt: date)]) }
        #expect(try await bodySizes(cache)["m"] == 2 * text.utf8.count)
        try await cache.write { try $0.saveBodies([.init(accountID: "a", messageID: "m", html: nil, plainText: nil, fetchedAt: date)]) }
        #expect(try await bodySizes(cache)["m"] == 0)
        let total = try await bodySizes(cache).values.reduce(0, +)
        #expect(try await cache.disposableContentUsage().bodyBytes == Int64(total))
        try await cache.write { tx in _ = try tx.deleteMessages(ids: ["other"], accountID: "a") }
        #expect(try await bodySizes(cache) == ["m": 0])
        #expect(try await cache.evictContent(for: [thread], keeping: [], now: date).evictedThreads == [thread])
        #expect(try await bodySizes(cache).isEmpty)
        try await cache.write { try $0.saveBodies([.init(accountID: "a", messageID: "m", html: html, plainText: nil, fetchedAt: date)]) }
        #expect(try await bodySizes(cache) == ["m": html.utf8.count])
        try await cache.resetDisposableCache()
        #expect(try await bodySizes(cache).isEmpty)
    }

    @Test func upgradeMeasuresBodiesAlreadyCached() async throws {
        let writer = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(writer, upTo: "sender-image-authentication-v1")
        let bodies: [(id: String, html: String?, text: String?)] = [
            ("both", "<p>Γιώργος</p>", "Élodie 👋"), ("text", nil, "plain"), ("none", nil, nil),
        ]
        try await writer.write { db in
            for body in bodies {
                try db.execute(sql: """
                    INSERT INTO message(accountID,id,threadID,historyID,date,snippet,sender,recipients,subject,sizeEstimate)
                    VALUES ('a',?,?,1,0,'','sender@example.test','me@example.test','',0)
                    """, arguments: [body.id, body.id])
                try db.execute(sql: "INSERT INTO messageBody(accountID,messageID,html,plainText,fetchedAt) VALUES ('a',?,?,?,0)",
                               arguments: [body.id, body.html, body.text])
            }
        }
        let cache = try MailCache(writer: writer)
        let expected = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, ($0.html?.utf8.count ?? 0) + ($0.text?.utf8.count ?? 0)) })
        #expect(try await bodySizes(cache) == expected)
        #expect(try await cache.disposableContentUsage().bodyBytes == Int64(expected.values.reduce(0, +)))
    }

    @Test func usageLeavesOutFreePagesAndCompactionEmptiesTheLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let cache = try MailCache.open(at: url)
        #expect(try await cache.read { try Int.fetchOne($0.db, sql: "PRAGMA journal_size_limit") } == MailCache.logSizeLimit)
        #expect(try await cache.write { try Int.fetchOne($0.db, sql: "PRAGMA journal_size_limit") } == MailCache.logSizeLimit)
        func fileSize(_ suffix: String = "") throws -> Int64 {
            try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false) + suffix)[.size] as? Int64 ?? 0
        }
        let text = String(repeating: "Cached mail ", count: 200_000)
        try await seed(cache, id: "m", thread: "t", plainText: text)
        try await cache.writer.writeWithoutTransaction { _ = try $0.checkpoint(.truncate) }
        let full = try await cache.disposableContentUsage()
        _ = try await cache.evictContent(for: [.init(accountID: "a", threadID: "t")], keeping: [], now: date)
        try await cache.writer.writeWithoutTransaction { _ = try $0.checkpoint(.truncate) }
        // The file keeps the freed pages until compaction, but they don't count.
        let fileBeforeCompaction = try fileSize()
        #expect(fileBeforeCompaction >= full.databaseBytes)
        #expect(try await full.databaseBytes - cache.disposableContentUsage().databaseBytes > Int64(text.utf8.count) / 2)
        try await cache.compactDisposableCache()
        #expect(try fileSize("-wal") == 0)
        #expect(try fileSize() < fileBeforeCompaction)
    }

    @Test(.timeLimit(.minutes(1))) func aReadDuringCompactionDoesNotPutTheTrimmedCacheOverBudgetAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cache.sqlite")
        let cache = try MailCache.open(at: url)
        let text = String(repeating: "Cached mail ", count: 200_000)
        for id in ["old", "kept"] { try await seed(cache, id: id, thread: id, plainText: text) }
        _ = try await cache.evictContent(for: [.init(accountID: "a", threadID: "old")], keeping: [], now: date)
        try await cache.writer.writeWithoutTransaction { _ = try $0.checkpoint(.truncate) }
        let trimmed = try await cache.disposableContentUsage().databaseBytes
        // A read that began before the VACUUM keeps its snapshot through it,
        // so the truncating checkpoint can't empty the log.
        let (reading, started) = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        async let read: Void = cache.writer.read { db in
            _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message")
            started.yield()
            release.wait()
        }
        for await _ in reading { break }
        do {
            defer { release.signal() }
            try await cache.compactDisposableCache()
        }
        try await read
        let log = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false) + "-wal")[.size] as? Int64 ?? 0
        #expect(log > trimmed / 2)
        // A trim pass measures again after compacting, and one that ends over
        // its budget evicts more on the next pass.
        #expect(try await cache.disposableContentUsage().databaseBytes <= trimmed)
    }

    /// Statements one content and one metadata eviction run, each of a
    /// single thread. Only those MailStore runs count: the search index's own
    /// statements, which SQLite reports with a leading `--` like other nested
    /// ones, depend on how its segments happen to be merged.
    private func evictionStatements(cachedThreads: Int) async throws -> [Int] {
        let cache = try MailCache.inMemory()
        for index in 0..<cachedThreads { try await seed(cache, id: "m\(index)", thread: "t\(index)") }
        let listed = try await cache.evictionCandidates(keeping: [], now: date).map(\.thread)
        try #require(listed.count == cachedThreads)
        let statements = OSAllocatedUnfairLock(initialState: 0)
        try await cache.writer.write { db in
            db.trace { event in
                guard case let .statement(statement) = event, !statement.sql.hasPrefix("--") else { return }
                statements.withLock { $0 += 1 }
            }
        }
        statements.withLock { $0 = 0 }
        #expect(try await cache.evictContent(for: [listed[0]], keeping: [], now: date).evictedThreads == [listed[0]])
        let content = statements.withLock { $0 }
        statements.withLock { $0 = 0 }
        #expect(try await cache.evictMetadata(for: [listed[1]], keeping: [], now: date).evictedThreads == [listed[1]])
        return [content, statements.withLock { $0 }]
    }

    /// Stored body sizes in account "a", by message.
    private func bodySizes(_ cache: MailCache) async throws -> [String: Int] {
        try await cache.read { tx in
            var sizes: [String: Int] = [:]
            for row in try Row.fetchAll(tx.db, sql: "SELECT messageID, bytes FROM messageBodySize WHERE accountID = 'a'") {
                sizes[row["messageID"]] = row["bytes"]
            }
            return sizes
        }
    }

    private func invitation(uid: String, method: String = "REQUEST", sequence: Int, stamp: String = "20310101T120000Z", recurrence: String? = nil) throws -> Invitation {
        let recurrenceLine = recurrence.map { "RECURRENCE-ID:\($0)\r\n" } ?? ""
        return try Invitation(data: Data(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:\(method)\r\n" +
            "BEGIN:VEVENT\r\nUID:\(uid)\r\nSEQUENCE:\(sequence)\r\nDTSTAMP:\(stamp)\r\n" +
            recurrenceLine + "DTSTART:20310715T140000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n").utf8))
    }

    private func seed(_ cache: MailCache, id: String, thread: String, account: String = "a", recent: Bool = false, inbox: Bool = false,
                      html: String? = "<b>Resource</b>", plainText: String? = "Resource") async throws {
        let timestamp = recent ? date : date.addingTimeInterval(-60 * 86400)
        let message = MessageRecord(accountID: account, id: id, threadID: thread, historyID: 1, date: timestamp,
            snippet: "", sender: "sender@example.test", recipients: "me@example.test", cc: nil, subject: "Mail", sizeEstimate: 1)
        try await cache.write { tx in
            try tx.upsertMessages([.init(record: message, labelIDs: inbox ? [SystemLabel.inbox] : [])])
            try tx.rebuildThreads([thread], accountID: account)
            try tx.saveBodies([.init(accountID: account, messageID: id, html: html, plainText: plainText, fetchedAt: date)])
        }
    }
}
