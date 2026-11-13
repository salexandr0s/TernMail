import Foundation
import GRDB
import MessageContent
import os
import Testing
@testable import MailStore

@Suite struct MessageListEntryTests {
    /// A stream given its tables isn't told about a change to any other, so
    /// each list in `ObservedTables` has to hold every table its read touches.
    @Test(.timeLimit(.minutes(1))) func observedTablesHoldEveryTableTheirReadTouches() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.replaceLabels([LabelRecord(accountID: "a", id: "Label_1", name: "Work", isSystem: false)], accountID: "a")
            let record = MessageRecord(accountID: "a", id: "m1", threadID: "t1", historyID: 1,
                date: Date(timeIntervalSince1970: 1), snippet: "", sender: "sender@example.com", recipients: "me@example.com",
                cc: nil, subject: "Planning", sizeEstimate: 1)
            try tx.upsertMessages([.init(record: record, labelIDs: [SystemLabel.inbox, "Label_1"])])
            try tx.rebuildThreads(["t1"], accountID: "a")
            try tx.replaceAttachments([.init(accountID: "a", messageID: "m1", partID: "file", attachmentID: "remote",
                filename: "notes.pdf", mimeType: "application/pdf", size: 20, isInline: false)], messageID: "m1", accountID: "a")
            try tx.holdSnooze(threadID: "t1", until: Date(timeIntervalSince1970: 2_000_000_000), accountID: "a")
            try tx.insertLocalDraft(LocalDraft(id: "L1", accountID: "a", kind: .new, rfcMessageID: "<L1@example.com>", now: .now))
            // A scan under way and a receipt request, so their reads go past the first statement.
            _ = try tx.beginNewsletterScan(accountID: "a")
            try tx.db.execute(sql: """
                INSERT INTO readReceiptRequest (accountID, rfcMessageID, senderAddress, subject, sentAt)
                VALUES ('a', '<L1@example.com>', 'me@example.com', 'Planning', ?)
                """, arguments: [Date(timeIntervalSince1970: 1)])
            try tx.db.execute(sql: """
                INSERT INTO readReceiptRecipient (accountID, rfcMessageID, address)
                VALUES ('a', '<L1@example.com>', 'sender@example.com')
                """)
        }
        let thread = try #require(try await cache.read { try $0.thread(id: "t1", accountID: "a") })
        let query = SearchQuery("plan label:work")
        let pages: [MailListPageBuilder] = [
            .mailbox(accountIDs: ["a"], labelID: SystemLabel.unread, limit: 10, retainingReadMessageIDs: ["a": ["m1"]]),
            .searchResults([thread], matching: query),
            .snoozed([thread]),
        ]
        for page in pages {
            #expect(try await tablesMissing(from: ObservedTables.listPage(page), in: cache) { db in
                try page.page(in: CacheTransaction(db: db))
            } == [])
        }
        #expect(try await tablesMissing(from: ObservedTables.messageList(matching: query, snoozedOnly: true), in: cache) { db in
            try CacheTransaction(db: db).messageListEntries(threadsByAccount: ["a": ["t1"]], matching: query, snoozedOnly: true, now: .now)
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.threadDetail, in: cache) { db in
            try CacheTransaction(db: db).threadDetail(threadID: "t1", accountID: "a")
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.threadList, in: cache) { db in
            try ThreadRecord.fetchAll(db, sql: ThreadListQuery.sql(accountCount: 1),
                arguments: ThreadListQuery.arguments(accountIDs: ["a"], labelID: SystemLabel.inbox, limit: 10))
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.labels, in: cache) { db in
            try CacheTransaction(db: db).displayedLabels(accountID: "a")
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.drafts, in: cache) { db in
            let tx = CacheTransaction(db: db)
            return try tx.localDrafts(accountID: "a").map { try tx.draftActivity($0) }
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.pendingChanges, in: cache) { db in
            try CacheTransaction(db: db).pendingChangeSummary(accountID: "a")
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.unreadCounts, in: cache) { db in
            try CacheTransaction(db: db).unreadCounts(accountID: "a")
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.threadLabels, in: cache) { db in
            try CacheTransaction(db: db).threadLabels(of: [(accountID: "a", threadID: "t1")], accountIDs: ["a"])
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.searchThreads, in: cache) { db in
            try CacheTransaction(db: db).searchThreads(query, accountID: "a", timeZone: .gmt, now: .now, limit: 10)
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.calendarInvitations, in: cache) { db in
            try CacheTransaction(db: db).calendarInvitationState(accountID: "a")
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.readReceipts, in: cache) { db in
            try CacheTransaction(db: db).readReceiptStatuses(accountID: "a", recipient: "sender@example.com")
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.newsletters, in: cache) { db in
            try CacheTransaction(db: db).newsletters(accountID: "a")
        } == [])
        #expect(try await tablesMissing(from: ObservedTables.attachmentLibrary, in: cache) { db in
            try CacheTransaction(db: db).attachmentLibrary(query: .init(accountIDs: ["a"], label: .init(accountID: "a", id: "Label_1")))
        } == [])
        for analytics in [MailAnalyticsQuery(accountIDs: ["a"], period: .month),
                          MailAnalyticsQuery(accountIDs: ["a"], contactAddress: "sender@example.com", period: .month)] {
            #expect(try await tablesMissing(from: ObservedTables.mailAnalytics(analytics), in: cache) { db in
                try CacheTransaction(db: db).mailAnalytics(query: analytics)
            } == [])
        }
        // A list one table short is caught.
        #expect(try await tablesMissing(from: ["label"], in: cache) { db in
            try CacheTransaction(db: db).displayedLabels(accountID: "a")
        } == ["pendingAction"])
    }

    /// The app's cache is a pool. There a stream given its tables reads
    /// again on a reader connection, so no write waits for the read.
    @Test(.timeLimit(.minutes(1))) func aStreamGivenItsTablesReadsAgainOffTheWriter() async throws {
        struct Read: Sendable, Equatable {
            var labels: Int
            var onReader: Bool
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "tern-observe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try MailCache.open(at: directory.appending(path: "cache.sqlite"))
        var values = cache.observe(region: ObservedTables.labels) { db in
            Read(labels: try CacheTransaction(db: db).labels(accountID: "a").count, onReader: db.configuration.readonly)
        }.makeAsyncIterator()
        #expect(try await values.next()?.labels == 0)
        try await cache.write { try $0.replaceLabels([LabelRecord(accountID: "a", id: "label", name: "Label", isSystem: false)], accountID: "a") }
        #expect(try await values.next() == Read(labels: 1, onReader: true))
    }

    @Test(.timeLimit(.minutes(1))) func slowSnapshotConsumerCatchesUpWithoutReplayingEveryWrite() async throws {
        let cache = try MailCache.inMemory()
        let fetches = AsyncStream<Void>.makeStream()
        var fetched = fetches.stream.makeAsyncIterator()
        var values = cache.observe(latestOnly: true, region: ["label"]) { db -> String? in
            let value = try CacheTransaction(db: db).labels(accountID: "a").first?.name
            fetches.continuation.yield()
            return value
        }.makeAsyncIterator()
        defer { fetches.continuation.finish() }
        let initial: String? = try #require(try await values.next())
        #expect(initial == nil)
        _ = await fetched.next()
        for index in 0..<20 {
            let label = LabelRecord(accountID: "a", id: "label", name: "Revision \(index)", isSystem: false)
            try await cache.write { try $0.replaceLabels([label], accountID: "a") }
            _ = await fetched.next()
        }
        // Fetch completion precedes delivery through GRDB's asynchronous bridge, so the
        // newest revision may still be on its way. The paused consumer skips ahead
        // instead of receiving each of the 20 revisions.
        var received = 0
        var latest: String?
        while latest != "Revision 19" {
            latest = try #require(try await values.next())
            received += 1
        }
        #expect(received < 20)
        try await cache.write { try $0.replaceLabels([], accountID: "a") }
        let deleted: String? = try #require(try await values.next())
        #expect(deleted == nil)
    }

    @Test func observationSkipsEqualSnapshotsAndRetainsInitialAndDeletedNil() async throws {
        let cache = try MailCache.inMemory()
        let fetches = AsyncStream<Void>.makeStream()
        var fetched = fetches.stream.makeAsyncIterator()
        var values = cache.observe(region: ["label"]) { db -> String? in
            let name = try CacheTransaction(db: db).labels(accountID: "a").first { $0.id == SystemLabel.inbox }?.name
            fetches.continuation.yield()
            return name
        }.makeAsyncIterator()
        defer { fetches.continuation.finish() }

        let initial: String? = try #require(try await values.next())
        #expect(initial == nil)
        _ = await fetched.next()
        let other = LabelRecord(accountID: "a", id: "other", name: "Other", isSystem: false)
        try await cache.write { try $0.replaceLabels([other], accountID: "a") }
        _ = await fetched.next()
        let inbox = LabelRecord(accountID: "a", id: SystemLabel.inbox, name: "Inbox", isSystem: true)
        try await cache.write { try $0.replaceLabels([inbox, other], accountID: "a") }
        _ = await fetched.next()
        #expect(try await values.next() == "Inbox")

        try await cache.write { try $0.replaceLabels([inbox], accountID: "a") }
        _ = await fetched.next()
        let renamed = LabelRecord(accountID: "a", id: SystemLabel.inbox, name: "Renamed", isSystem: true)
        try await cache.write { try $0.replaceLabels([renamed], accountID: "a") }
        _ = await fetched.next()
        #expect(try await values.next() == "Renamed")

        try await cache.write { try $0.replaceLabels([], accountID: "a") }
        let deleted: String? = try #require(try await values.next())
        #expect(deleted == nil)
    }

    @Test func messageModeSearchKeepsLocalPrefixesAndExactServerMatchesWithoutSiblings() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            for id in ["match", "sibling"] {
                let message = MessageRecord(accountID: "a", id: id, threadID: "thread", historyID: 1,
                    date: Date(timeIntervalSince1970: 1), snippet: "", sender: "sender@example.com", recipients: "me@example.com",
                    cc: nil, subject: id == "match" ? "Planning" : "Other", sizeEstimate: 1)
                try tx.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox])])
            }
            try tx.rebuildThreads(["thread"], accountID: "a")
        }
        var local = cache.messageListEntries(threadsByAccount: ["a": ["thread"]], matching: SearchQuery("plan")).makeAsyncIterator()
        #expect(try await local.next()?.map(\.message.id) == ["match"])
        var remote = cache.messageListEntries(threadsByAccount: ["a": ["thread"]], matching: SearchQuery("has:attachment"),
            includingMessageIDs: ["a": ["sibling"], "b": ["match"]]).makeAsyncIterator()
        #expect(try await remote.next()?.map(\.message.id) == ["sibling"])
    }

    @Test func messageRowsKeepAccountBoundariesAttachmentsAndExactPendingLabels() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            for account in ["a", "b"] {
                for id in ["m1", "m2"] {
                    let record = MessageRecord(accountID: account, id: id, threadID: "thread", historyID: 1,
                        date: Date(timeIntervalSince1970: id == "m1" ? 1 : 2), snippet: "", sender: "sender@example.com",
                        recipients: "me@example.com", cc: nil, subject: "Planning", sizeEstimate: 1)
                    try tx.upsertMessages([.init(record: record, labelIDs: [SystemLabel.inbox, SystemLabel.unread])])
                }
                try tx.rebuildThreads(["thread"], accountID: account)
            }
            try tx.replaceAttachments([.init(accountID: "a", messageID: "m1", partID: "file", attachmentID: "remote",
                filename: "notes.pdf", mimeType: "application/pdf", size: 20, isInline: false)], messageID: "m1", accountID: "a")
            _ = try tx.enqueue(.modifyMessages, accountID: "a", messageIDs: ["m1"], remove: [SystemLabel.unread], now: .now, notBefore: .now)
        }
        var iterator = cache.messageListEntries(threadsByAccount: ["a": ["thread"]]).makeAsyncIterator()
        let entries = try #require(try await iterator.next())
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.message.accountID == "a" })
        #expect(entries.first(where: { $0.message.id == "m1" })?.rowThread.isUnread == false)
        #expect(entries.first(where: { $0.message.id == "m2" })?.rowThread.isUnread == true)
        #expect(entries.first(where: { $0.message.id == "m1" })?.attachments.first?.filename == "notes.pdf")
        #expect(entries.first(where: { $0.message.id == "m2" })?.attachments.isEmpty == true)
    }

    @Test func navigationObservationSeesRenamingWithoutChangingRowCount() async throws {
        let store = try AccountStore.inMemory()
        var iterator = store.mailNavigationChanges().makeAsyncIterator()
        _ = try #require(try await iterator.next())
        let search = SavedMailSearch(id: "search", name: "First", query: "is:unread")
        try await store.saveSavedMailSearch(search)
        _ = try #require(try await iterator.next())
        var renamed = search
        renamed.name = "Renamed"
        try await store.saveSavedMailSearch(renamed)
        _ = try #require(try await iterator.next())
        #expect(try await store.savedMailSearches().map(\.name) == ["Renamed"])
    }
}

/// The tables `fetch` reads that `tables` leaves out, as GRDB records the
/// read, and any name in `tables` the cache has no table for.
private func tablesMissing<T: Sendable>(
    from tables: [String], in cache: MailCache, _ fetch: @escaping @Sendable (Database) throws -> T
) async throws -> [String] {
    let existing = try await cache.read { tx in try String.fetchSet(tx.db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") }
    let read = OSAllocatedUnfairLock(initialState: Set<String>())
    let observation = ValueObservation.tracking(fetch).handleEvents(willTrackRegion: { region in
        read.withLock { $0 = existing.filter { region.isModified(byEventsOfKind: .insert(tableName: $0)) } }
    })
    for try await _ in observation.values(in: cache.writer) { break }
    let unlisted = read.withLock { $0 }.subtracting(tables)
    return unlisted.sorted() + Set(tables).subtracting(existing).sorted().map { "no table \($0)" }
}
