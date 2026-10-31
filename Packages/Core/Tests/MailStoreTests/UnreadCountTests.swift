import Foundation
import GRDB
import Testing
@testable import MailStore

private let account = "acct"
private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// A badge has to move with the list: a local change counts at once and
/// keeps counting until Gmail's own counts include it.
@Suite struct UnreadCountTests {
    @Test func anArchivedConversationLeavesTheInboxCountUntilGmailCountsIt() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.replaceLabels(
                [label(SystemLabel.inbox, threads: 2, messages: 3), label(SystemLabel.unread, threads: 2, messages: 3)],
                accountID: account
            )
            try tx.rebuildThreads(try tx.upsertMessages([
                message("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread]),
                message("m2", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread], minutes: 5),
                message("m3", thread: "t2", labels: [SystemLabel.inbox, SystemLabel.unread], minutes: 10),
            ]), accountID: account)
        }
        let queued = try await cache.write { tx in
            try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: start, notBefore: start)
        }
        var archive = try #require(queued)
        // The Inbox count drops with the row, before Gmail hears of it. The
        // conversation is still unread.
        let archived = LabelCounts(threadsUnread: 1, messagesUnread: 1, includesLocalChanges: true)
        #expect(try await counts(cache)[SystemLabel.inbox] == archived)
        #expect(try await counts(cache)[SystemLabel.unread] == LabelCounts(threadsUnread: 2, messagesUnread: 3, includesLocalChanges: false))

        // Gmail accepts it, and the pass that brings its history drops the
        // queue row before the labels are asked for again.
        archive.state = .sent
        archive.sentAt = start.addingTimeInterval(1)
        try await cache.write { [archive] tx in
            try tx.updateAction(archive)
            for id in ["m1", "m2"] {
                _ = try tx.applyLabelChange(messageID: id, added: [], removed: [SystemLabel.inbox], historyID: 200, accountID: account)
            }
            try tx.dropSentActions(confirmedThrough: 200, passStart: start.addingTimeInterval(2), accountID: account)
        }
        #expect(try await cache.read { try $0.pendingActions(accountID: account) }.isEmpty)
        #expect(try await counts(cache)[SystemLabel.inbox] == archived)

        // Counts Gmail took before the send don't hold the change; counts
        // taken after it do, and the local change stops counting.
        try await cache.write { tx in
            try tx.saveLabels([label(SystemLabel.inbox, threads: 2, messages: 3)], accountID: account, countedAt: start)
        }
        #expect(try await counts(cache)[SystemLabel.inbox] == archived)
        try await cache.write { tx in
            try tx.saveLabels([label(SystemLabel.inbox, threads: 1, messages: 1)], accountID: account, countedAt: start.addingTimeInterval(3))
        }
        #expect(try await counts(cache)[SystemLabel.inbox] == LabelCounts(threadsUnread: 1, messagesUnread: 1, includesLocalChanges: false))
    }

    @Test func aChangeGmailNeverAcceptsStopsCounting() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.replaceLabels([label(SystemLabel.inbox, threads: 1, messages: 2), label("Label_1", threads: 1, messages: 1)], accountID: account)
            try tx.rebuildThreads(try tx.upsertMessages([
                message("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread, "Label_1"]),
                message("m2", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread], minutes: 5),
            ]), accountID: account)
        }
        let unread = [
            SystemLabel.inbox: LabelCounts(threadsUnread: 1, messagesUnread: 2, includesLocalChanges: false),
            "Label_1": LabelCounts(threadsUnread: 1, messagesUnread: 1, includesLocalChanges: false),
        ]
        // Reading the conversation clears it from every label it carries:
        // one conversation each, and each label's own unread messages.
        let read = [
            SystemLabel.inbox: LabelCounts(threadsUnread: 0, messagesUnread: 0, includesLocalChanges: true),
            "Label_1": LabelCounts(threadsUnread: 0, messagesUnread: 0, includesLocalChanges: true),
        ]
        let queued = try await cache.write { tx in
            try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.unread], now: start, notBefore: start)
        }
        let markRead = try #require(queued)
        let id = try #require(markRead.id)
        #expect(try await counts(cache) == read)

        // Refused: the conversation is unread again, and so are the counts.
        try await cache.write { tx in try tx.retainFailedAction(markRead, message: "Refused") }
        #expect(try await counts(cache) == unread)

        // A retry counts again; undoing it before it goes out stops it for good.
        _ = try await cache.write { tx in try tx.retryFailedAction(id: id, accountID: account, now: start) }
        #expect(try await counts(cache) == read)
        try await cache.write { tx in try tx.deleteAction(id: id) }
        #expect(try await counts(cache) == unread)
    }
}

private func counts(_ cache: MailCache) async throws -> [String: LabelCounts] {
    try await cache.read { tx in try tx.unreadCounts(accountID: account) }
}

private func message(_ id: String, thread: String, labels: [String], minutes: Double = 0) -> CacheTransaction.MessageUpdate {
    CacheTransaction.MessageUpdate(
        record: MessageRecord(
            accountID: account, id: id, threadID: thread, historyID: 100,
            date: start.addingTimeInterval(minutes * 60),
            snippet: "Snippet", sender: "Sender <s@example.com>", recipients: "r@example.com",
            cc: nil, subject: "Subject", sizeEstimate: 1
        ),
        labelIDs: labels
    )
}

private func label(_ id: String, threads: Int, messages: Int) -> LabelRecord {
    LabelRecord(
        accountID: account, id: id, name: id, isSystem: !id.hasPrefix("Label_"),
        threadsUnread: threads, messagesUnread: messages
    )
}
