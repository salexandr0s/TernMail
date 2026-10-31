import Foundation
import GRDB
import Testing
@testable import MailStore

private let account = "acct"

/// A write that brings no news has to leave every row as it was, so no list
/// or sidebar observer wakes for it. SQLite counts the rows an UPDATE touches
/// even when it sets the same values, so `totalChangesCount` is the measure.
@Suite struct UnchangedWriteTests {
    @Test func aPassThatChangesNothingWritesNoRow() async throws {
        let cache = try MailCache.inMemory()
        let labels = [label(SystemLabel.inbox, unread: 3), label(SystemLabel.sent, unread: 0)]
        let updates = [
            message("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread]),
            message("m2", thread: "t1", labels: [SystemLabel.inbox], minutes: 5),
            message("m3", thread: "t2", labels: [SystemLabel.sent], minutes: 10),
        ]
        let attachments = [attachment("1"), attachment("2")]
        try await cache.write { tx in
            try tx.replaceLabels(labels, accountID: account)
            try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: account)
            try tx.replaceAttachments(attachments, messageID: "m2", accountID: account)
        }

        let (changedRows, changedThreads) = try await cache.write { tx -> (Int, Set<String>) in
            let before = tx.db.totalChangesCount
            try tx.replaceLabels(labels, accountID: account)
            let threads = try tx.upsertMessages(updates)
            try tx.rebuildThreads(["t1", "t2"], accountID: account)
            try tx.replaceAttachments(attachments, messageID: "m2", accountID: account)
            return (tx.db.totalChangesCount - before, threads)
        }
        #expect(changedRows == 0)
        #expect(changedThreads.isEmpty)
    }

    @Test func anOpenedConversationStaysOpenedThroughARebuild() async throws {
        let cache = try MailCache.inMemory()
        let openedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await cache.write { tx in
            try tx.rebuildThreads(try tx.upsertMessages([message("m1", thread: "t1", labels: [SystemLabel.inbox])]), accountID: account)
            try tx.markThreadOpened(threadID: "t1", accountID: account, at: openedAt)
        }
        try await cache.write { tx in
            let threads = try tx.upsertMessages([message("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.starred], historyID: 101)])
            try tx.rebuildThreads(threads, accountID: account)
        }
        let opened = try await cache.read { tx in
            try Date.fetchOne(tx.db, sql: "SELECT lastOpenedAt FROM threadOpened WHERE accountID = ? AND threadID = ?", arguments: [account, "t1"])
        }
        #expect(opened == openedAt)
        #expect(try await cache.read { try $0.thread(id: "t1", accountID: account)?.isStarred } == true)
    }

    @Test func onlyTheRowsAChangeRemovesAreDeleted() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.replaceLabels([label(SystemLabel.inbox, unread: 1), label("Label_1", unread: 0)], accountID: account)
            try tx.rebuildThreads(try tx.upsertMessages([message("m1", thread: "t1", labels: [SystemLabel.inbox, "Label_1"])]), accountID: account)
            try tx.replaceAttachments([attachment("1", messageID: "m1"), attachment("2", messageID: "m1")], messageID: "m1", accountID: account)
        }
        try await cache.write { tx in
            try tx.replaceLabels([label(SystemLabel.inbox, unread: 0)], accountID: account)
            try tx.rebuildThreads(try tx.upsertMessages([message("m1", thread: "t1", labels: ["Label_1"], historyID: 101)]), accountID: account)
            try tx.replaceAttachments([attachment("2", messageID: "m1")], messageID: "m1", accountID: account)
        }
        let listed = try await cache.read { tx in
            try String.fetchSet(tx.db, sql: "SELECT labelID FROM threadLabel WHERE accountID = ? AND threadID = ?", arguments: [account, "t1"])
        }
        #expect(listed == ["Label_1", SystemLabel.allMail])
        #expect(try await cache.read { try $0.labels(accountID: account).map { ($0.id, $0.threadsUnread) } }.map(\.0) == [SystemLabel.inbox])
        #expect(try await cache.read { try $0.labels(accountID: account).first?.threadsUnread } == 0)
        #expect(try await cache.read { tx in
            try AttachmentRecord.filter(Column("accountID") == account && Column("messageID") == "m1").fetchAll(tx.db).map(\.partID)
        } == ["2"])
    }
}

private func message(
    _ id: String, thread: String, labels: [String], minutes: Double = 0, historyID: Int64 = 100
) -> CacheTransaction.MessageUpdate {
    CacheTransaction.MessageUpdate(
        record: MessageRecord(
            accountID: account, id: id, threadID: thread, historyID: historyID,
            date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60),
            snippet: "Snippet", sender: "Sender <s@example.com>", recipients: "r@example.com",
            cc: nil, subject: "Subject", sizeEstimate: 1
        ),
        labelIDs: labels
    )
}

private func label(_ id: String, unread: Int) -> LabelRecord {
    LabelRecord(accountID: account, id: id, name: id, isSystem: !id.hasPrefix("Label_"), threadsUnread: unread)
}

private func attachment(_ partID: String, messageID: String = "m2") -> AttachmentRecord {
    AttachmentRecord(accountID: account, messageID: messageID, partID: partID, attachmentID: "a\(partID)",
                     filename: "file\(partID).pdf", mimeType: "application/pdf", size: 10, isInline: false)
}
