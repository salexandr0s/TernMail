import Foundation
import GRDB
import Testing
@testable import MailStore
import MessageContent

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
        #expect(action.diff == ["m1": .init(added: [], removed: [SystemLabel.inbox]), "m2": .init(added: [], removed: [])])
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
            // A history change raises the message's history ID, so a thread fetch
            // started before it can't undo it.
            _ = try tx.applyLabelChange(
                messageID: "m1", added: [SystemLabel.starred], removed: [], historyID: 220, accountID: account
            )
            try tx.upsertMessages([update("m1", thread: "t1", labels: [SystemLabel.inbox], historyID: 210)])
            // History and openThread can finish in either order.
            _ = try tx.applyLabelChange(
                messageID: "m1", added: [SystemLabel.unread], removed: [SystemLabel.starred], historyID: 210, accountID: account
            )
            // Two changes in one record share a history ID and must both apply.
            _ = try tx.applyLabelChange(
                messageID: "m1", added: [], removed: [SystemLabel.inbox], historyID: 220, accountID: account
            )
        }

        #expect(try await serverLabels(cache, "m1") == [SystemLabel.starred])
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

@Suite struct DraftStoreTests {
    @Test func localDraftsKeepTheirContentAndTakeEditsOnlyWhileEditing() async throws {
        let cache = try MailCache.inMemory()
        let link = try #require(URL(string: "https://example.com"))
        let original = DraftContent(
            to: [EmailAddress(name: "Zoë", address: "zoe@example.com")],
            subject: "Plans",
            body: ComposeDocument(blocks: [.init(runs: [.init("Hi", bold: true), .init(" there", link: link)])])
        )
        var content = original
        content.subject = "Re: Plans"
        let draft = LocalDraft(id: "L1", accountID: account, kind: .reply, content: original, rfcMessageID: "<a@example.com>", references: ["<r@example.com>"], now: .now)

        let stored = try await cache.write { [content] tx in
            try tx.insertLocalDraft(draft)
            let edited = try tx.updateLocalDraft(id: "L1", content: content, now: .now)
            let file = OutgoingAttachment(localDraftID: "L1", filename: "a.pdf", mimeType: "application/pdf", size: 3, path: "L1/a.pdf")
            _ = try tx.addOutgoingAttachment(file, now: .now)
            return edited
        }
        #expect(stored?.content == content)
        #expect(stored?.references == ["<r@example.com>"])
        let reloaded = try await cache.read { tx in try tx.localDraft(id: "L1") }
        #expect(reloaded?.revision == 2)
        #expect(reloaded?.content == content)

        let refused = try await cache.write { tx in
            var sending = try #require(try tx.localDraft(id: "L1"))
            sending.state = .sending
            try sending.update(tx.db)
            return try tx.updateLocalDraft(id: "L1", content: DraftContent(subject: "Lost"), now: .now)
        }
        #expect(refused == nil)

        let removed = try await cache.write { tx in try tx.deleteLocalDraft(id: "L1") }
        #expect(removed.map(\.filename) == ["a.pdf"])
        #expect(try await cache.read { tx in try tx.outgoingAttachments(localDraftID: "L1") }.isEmpty)
    }

    @Test func aSaveReplacesTheDraftsEarlierMessage() async throws {
        let cache = try MailCache.inMemory()
        let replaced = try await cache.write { tx in
            try tx.upsertMessages([
                update("m1", thread: "t1", labels: [SystemLabel.inbox]),
                update("d-old", thread: "t1", labels: [SystemLabel.draft], minutes: 1),
            ])
            try tx.rebuildThreads(["t1"], accountID: account)
            try tx.replaceDrafts([DraftRecord(accountID: account, id: "D1", messageID: "d-old", threadID: "t1")], accountID: account)
            try tx.insertLocalDraft(LocalDraft(id: "L1", accountID: account, kind: .reply, rfcMessageID: "<a@example.com>", gmailDraftID: "D1", savedMessageID: "d-old", threadID: "t1", now: .now))

            return try tx.recordDraftSave(
                DraftRecord(accountID: account, id: "D1", messageID: "d-new", threadID: "t1"),
                localDraftID: "L1", revision: 3,
                message: update("d-new", thread: "t1", labels: [SystemLabel.draft], minutes: 2)
            )
        }

        #expect(replaced == ["d-old"])
        let state = try await cache.read { tx in
            (try tx.messages(threadID: "t1", accountID: account).map(\.id), try tx.localDraft(id: "L1"), try tx.draft(id: "D1", accountID: account))
        }
        #expect(state.0 == ["m1", "d-new"])
        #expect(state.1?.savedMessageID == "d-new")
        #expect(state.1?.savedRevision == 3)
        #expect(state.2?.messageID == "d-new")
        #expect(try await threadIDs(cache, SystemLabel.draft) == ["t1"])

        // A listing taken before the save finished must not drop its draft.
        try await cache.write { tx in
            try tx.replaceDrafts([DraftRecord(accountID: account, id: "D9", messageID: "x", threadID: "t9")], accountID: account)
        }
        let drafts = try await cache.read { tx in try DraftRecord.order(Column("id")).fetchAll(tx.db).map(\.id) }
        #expect(drafts == ["D1", "D9"])
    }

    @Test func aQueuedSendHidesTheDraftUntilUndoneAndThenUntilItIsSent() async throws {
        let cache = try MailCache.inMemory()
        let edit = DraftContent(subject: "Final words")
        try await cache.write { tx in
            try tx.upsertMessages([
                update("m1", thread: "t1", labels: [SystemLabel.inbox]),
                update("d1", thread: "t1", labels: [SystemLabel.draft], minutes: 1),
            ])
            try tx.replaceDrafts([DraftRecord(accountID: account, id: "D1", messageID: "d1", threadID: "t1")], accountID: account)
            try tx.insertLocalDraft(LocalDraft(id: "L1", accountID: account, kind: .reply, rfcMessageID: "<a@example.com>", gmailDraftID: "D1", savedMessageID: "d1", threadID: "t1", now: .now))
            try tx.rebuildThreads(["t1"], accountID: account)
            #expect(try tx.enqueueSave(localDraftID: "L1", now: .now, notBefore: .now) != nil)
            #expect(try tx.enqueueSave(localDraftID: "L1", now: .now, notBefore: .now) == nil)
            #expect(try tx.enqueueSend(localDraftID: "L1", content: edit, now: .now, notBefore: .now) != nil)
        }
        #expect(try await composeKinds(cache) == [.sendDraft])
        #expect(try await threadIDs(cache, SystemLabel.draft).isEmpty)
        #expect(try await cache.read { tx in try tx.thread(id: "t1", accountID: account)?.messageCount } == 1)
        #expect(try await cache.read { tx in try tx.localDraft(id: "L1")?.subject } == "Final words")
        let detail = try await first(cache.thread(accountID: account, threadID: "t1"))
        #expect(detail??.messages.map(\.id) == ["m1"])
        #expect(try await first(cache.outbox(accountID: account))?.map(\.id) == ["L1"])

        let undone = try await cache.write { tx in
            #expect(try tx.updateLocalDraft(id: "L1", content: DraftContent(), now: .now) == nil)
            return try tx.cancelExit(localDraftID: "L1")
        }
        #expect(undone)
        #expect(try await composeKinds(cache).isEmpty)
        #expect(try await threadIDs(cache, SystemLabel.draft) == ["t1"])

        // Once the send has been claimed, undo is too late.
        let sent = update("s1", thread: "t1", labels: [SystemLabel.sent], minutes: 2)
        let finished = try await cache.write { tx in
            _ = try tx.enqueueSend(localDraftID: "L1", now: .now, notBefore: .now)
            #expect(try tx.claimDueActions(accountID: account, now: .now, lane: .compose).map(\.kind) == [.sendDraft])
            #expect(try !tx.cancelExit(localDraftID: "L1"))
            return try tx.removeFinishedDraft(localDraftID: "L1", sentMessage: sent)
        }
        #expect(finished.removedMessageIDs == ["d1"])
        let after = try await cache.read { tx in
            (try tx.messages(threadID: "t1", accountID: account).map(\.id), try tx.localDraft(id: "L1"), try tx.draft(id: "D1", accountID: account))
        }
        #expect(after.0 == ["m1", "s1"])
        #expect(after.1 == nil && after.2 == nil)
        #expect(try await pendingKinds(cache).isEmpty)
    }

    @Test func draftRowsClaimInTheirOwnLaneAndInOrderPerDraft() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([update("m1", thread: "t1", labels: [SystemLabel.inbox])])
            try tx.rebuildThreads(["t1"], accountID: account)
            for id in ["L1", "L2"] {
                try tx.insertLocalDraft(LocalDraft(id: id, accountID: account, kind: .new, rfcMessageID: "<\(id)@example.com>", now: .now))
            }
            _ = try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: .now, notBefore: .now)
            try tx.enqueueSave(localDraftID: "L1", now: .now, notBefore: .now)
            #expect(try tx.claimDueActions(accountID: account, now: .now, lane: .compose).map(\.localDraftID) == ["L1"])
            // A send queued while the save uploads waits for it.
            _ = try tx.enqueueSend(localDraftID: "L1", now: .now, notBefore: .now)
            try tx.enqueueSave(localDraftID: "L2", now: .now, notBefore: .now)
        }

        let compose = try await cache.write { tx in try tx.claimDueActions(accountID: account, now: .now, lane: .compose) }
        let labels = try await cache.write { tx in try tx.claimDueActions(accountID: account, now: .now) }
        #expect(compose.map(\.localDraftID) == ["L2"])
        #expect(labels.map(\.kind) == [.modifyThreads])
    }
}

@Suite struct AddressSuggestionTests {
    @Test func prefixMatchesComeFirstThenTheMostFrequent() async throws {
        let cache = try MailCache.inMemory()
        let messages = [
            ("Pat Lee <pat@example.com>", "me@example.com", nil),
            ("me@example.com", "pat@example.com, Paula Diaz <paula@example.com>", nil),
            ("Sam <sam@example.com>", "me@example.com", "Rupa <rupa@example.com>"),
            ("Pat Lee <pat@example.com>", "Me <me@example.com>", nil),
        ]
        try await cache.write { tx in
            _ = try tx.upsertMessages(messages.enumerated().map { index, headers in
                var change = update("m\(index)", thread: "t\(index)", labels: [SystemLabel.inbox], minutes: Double(index))
                change.record.sender = headers.0
                change.record.recipients = headers.1
                change.record.cc = headers.2
                return change
            })
        }
        let suggestions = try await cache.addressSuggestions(accountID: account, matching: "pa", excluding: ["me@example.com"])
        #expect(suggestions == [
            EmailAddress(name: "Pat Lee", address: "pat@example.com"),
            EmailAddress(name: "Paula Diaz", address: "paula@example.com"),
            // "pa" is inside the name, not at the start of a word.
            EmailAddress(name: "Rupa", address: "rupa@example.com"),
        ])
        #expect(try await cache.addressSuggestions(accountID: account, matching: "me", excluding: ["me@example.com"]).isEmpty)
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

private func pendingKinds(_ cache: MailCache) async throws -> [PendingAction.Kind] {
    try await cache.read { tx in try tx.pendingActions(accountID: account).map(\.kind) }
}

private func composeKinds(_ cache: MailCache) async throws -> [PendingAction.Kind] {
    try await cache.read { tx in try tx.composeRows(localDraftID: "L1").map(\.kind) }
}

private func first<T>(_ stream: AsyncThrowingStream<T, any Error>) async throws -> T? {
    for try await value in stream { return value }
    return nil
}
