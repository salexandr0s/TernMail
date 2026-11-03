import Foundation
import MessageContent
import Testing
@testable import MailStore

@Suite struct MessageListEntryTests {
    @Test func slowSnapshotConsumerCatchesUpWithoutReplayingEveryWrite() async throws {
        let cache = try MailCache.inMemory()
        let fetches = AsyncStream<Void>.makeStream()
        var fetched = fetches.stream.makeAsyncIterator()
        var values = cache.observe(latestOnly: true) { db -> String? in
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
        // Fetch completion precedes delivery through GRDB's asynchronous bridge.
        // Let that bridge drain while deliberately leaving our consumer paused.
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await values.next() == "Revision 19")
        try await cache.write { try $0.replaceLabels([], accountID: "a") }
        let deleted: String? = try #require(try await values.next())
        #expect(deleted == nil)
    }

    @Test func observationSkipsEqualSnapshotsAndRetainsInitialAndDeletedNil() async throws {
        let cache = try MailCache.inMemory()
        let fetches = AsyncStream<Void>.makeStream()
        var fetched = fetches.stream.makeAsyncIterator()
        var values = cache.observe { db -> String? in
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
