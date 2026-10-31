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

        let action = try #require(try await cache.write { tx in
            try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: .now, notBefore: .now)
        })
        #expect(action.diff == ["m1": .init(added: [], removed: [SystemLabel.inbox]), "m2": .init(added: [], removed: [])])
        #expect(try await threadIDs(cache, SystemLabel.inbox).isEmpty)
        #expect(try await threadIDs(cache, SystemLabel.allMail) == ["t1"])
        #expect(try await serverLabels(cache, "m1") == [SystemLabel.inbox, SystemLabel.unread])

        let id = try #require(action.id)
        try await cache.write { tx in try tx.deleteAction(id: id) }
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
    }

    @Test func aSentThreadChangeLeavesMessagesThatArrivedLaterAlone() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([update("m1", thread: "t1", labels: [SystemLabel.inbox])])
            try tx.rebuildThreads(["t1"], accountID: account)
        }
        var action = try #require(try await cache.write { tx in
            try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: .now, notBefore: .now)
        })
        // While the change waits, a reply that arrives is archived with the rest.
        try await cache.write { tx in
            try tx.upsertMessages([update("m2", thread: "t1", labels: [SystemLabel.inbox], minutes: 5)])
            try tx.rebuildThreads(["t1"], accountID: account)
        }
        #expect(try await threadIDs(cache, SystemLabel.inbox).isEmpty)

        // Once Gmail has applied it, only the messages it knew about are archived.
        action.state = .sent
        action.sentAt = .now
        try await cache.write { [action] tx in
            try tx.updateAction(action)
            try tx.rebuildThreads(["t1"], accountID: account)
        }
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        let labels = try await cache.read { tx in
            try tx.effectiveLabels(threadID: "t1", accountID: account, actions: try tx.pendingActions(accountID: account))
        }
        #expect(labels["m1"] == [])
        #expect(labels["m2"] == [SystemLabel.inbox])
    }

    @Test func aChangeThatAltersNoKnownLabelIsNotQueued() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([
                update("m1", thread: "t1", labels: [SystemLabel.sent]),
                update("m2", thread: "t2", labels: [SystemLabel.trash]),
            ])
            try tx.rebuildThreads(["t1", "t2"], accountID: account)
        }
        let rows = try await cache.write { tx in
            [
                try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: .now, notBefore: .now),
                try tx.enqueue(.modifyMessages, accountID: account, messageIDs: ["m1"], remove: [SystemLabel.unread], now: .now, notBefore: .now),
                try tx.enqueue(.trashThreads, accountID: account, threadIDs: ["t2"], add: [SystemLabel.trash], now: .now, notBefore: .now),
            ]
        }
        #expect(rows.allSatisfy { $0 == nil })
        #expect(try await pendingKinds(cache).isEmpty)

        // A deletion has no label diff, and the cache may not know every message.
        let kept = try await cache.write { tx in
            [
                try tx.enqueue(.deleteMessages, accountID: account, messageIDs: ["m2"], now: .now, notBefore: .now),
                try tx.enqueue(.modifyMessages, accountID: account, messageIDs: ["m1", "m9"], remove: [SystemLabel.unread], now: .now, notBefore: .now),
            ]
        }
        #expect(kept.allSatisfy { $0 != nil })
    }

    @Test func aCombinedListKeepsTheSameThreadIDFromTwoAccountsApart() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([
                update("m1", thread: "t1", labels: [SystemLabel.inbox]),
                update("m1", thread: "t1", labels: [SystemLabel.inbox], minutes: 5, in: "other"),
                update("m2", thread: "t2", labels: [SystemLabel.sent], minutes: 10, in: "other"),
            ])
            try tx.rebuildThreads(["t1"], accountID: account)
            try tx.rebuildThreads(["t1", "t2"], accountID: "other")
        }
        let combined = try #require(try await first(
            cache.threads(accountIDs: [account, "other"], labelID: SystemLabel.inbox, limit: 10)
        ))
        #expect(combined.map { "\($0.accountID)/\($0.id)" } == ["other/t1", "\(account)/t1"])
        let one = try #require(try await first(cache.threads(accountIDs: [account], labelID: SystemLabel.inbox, limit: 10)))
        #expect(one.map(\.accountID) == [account])
    }

    @Test func cachedAccountIDsDropAnAccountOnceItsDataIsDeleted() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertMessages([
                update("m1", thread: "t1", labels: [SystemLabel.inbox]),
                update("m1", thread: "t1", labels: [SystemLabel.inbox], minutes: 5, in: "other"),
            ])
        }
        #expect(try await cache.read { tx in try tx.cachedAccountIDs() } == [account, "other"])
        try await cache.write { tx in try tx.deleteAccountData(accountID: "other") }
        #expect(try await cache.read { tx in try tx.cachedAccountIDs() } == [account])
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
            #expect(try tx.enqueueSend(localDraftID: "L1", content: edit, now: .now, notBefore: .now, rendering: rendering) != nil)
        }
        #expect(try await composeKinds(cache) == [.sendDraft])
        #expect(try await threadIDs(cache, SystemLabel.draft).isEmpty)
        // The send's provisional message takes the draft's place.
        let provisional = LocalSend.messageID(localDraftID: "L1")
        #expect(try await cache.read { tx in try tx.thread(id: "t1", accountID: account)?.messageCount } == 2)
        #expect(try await cache.read { tx in try tx.localDraft(id: "L1")?.subject } == "Final words")
        let detail = try await first(cache.thread(accountID: account, threadID: "t1"))
        #expect(Set(detail??.messages.map(\.id) ?? []) == ["m1", provisional])
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
        // A whole millisecond, which the store keeps exactly.
        let due = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let finished = try await cache.write { tx in
            _ = try tx.enqueueSend(localDraftID: "L1", now: due, notBefore: due, rendering: rendering)
            #expect(try tx.claimDueActions(accountID: account, now: due, lane: .compose).map(\.kind) == [.sendDraft])
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

    @Test func aProvisionalSendOpensWithoutGmailAndNoChangeNamesIt() async throws {
        let cache = try MailCache.inMemory()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let me = EmailAddress(name: "Lee, Pat", address: "me@example.com")
        let words = LocalSend.Rendering(sender: me, html: "<p>Sent words</p>", plainText: "Sent words")
        let (reply, new) = (LocalSend.messageID(localDraftID: "L1"), LocalSend.messageID(localDraftID: "L2"))
        let changes = try await cache.write { tx in
            try tx.upsertMessages([update("m1", thread: "t1", labels: [SystemLabel.inbox])])
            try tx.rebuildThreads(["t1"], accountID: account)
            try tx.insertLocalDraft(LocalDraft(id: "L1", accountID: account, kind: .reply, rfcMessageID: "<L1@example.com>", threadID: "t1", now: now))
            try tx.insertLocalDraft(LocalDraft(id: "L2", accountID: account, kind: .new, rfcMessageID: "<L2@example.com>", now: now))
            for id in ["L1", "L2"] {
                _ = try tx.enqueueSend(localDraftID: id, now: now, notBefore: now, rendering: { _ in words })
            }
            return (
                starred: try tx.enqueue(.modifyMessages, accountID: account, messageIDs: [reply], add: [SystemLabel.starred], now: now, notBefore: now),
                trashed: try tx.enqueue(.trashThreads, accountID: account, threadIDs: [new], add: [SystemLabel.trash], now: now, notBefore: now),
                archived: try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: now, notBefore: now)
            )
        }
        // Gmail hears only of the messages it knows.
        #expect(changes.starred == nil && changes.trashed == nil)
        #expect(changes.archived.map { Set($0.diff.keys) } == ["m1"])
        #expect(try await serverLabels(cache, reply) == [SystemLabel.sent, LocalSend.label])
        #expect(try await threadIDs(cache, SystemLabel.sent) == [new, "t1"])

        let stored = try await cache.read { tx in
            (
                try tx.message(id: reply, accountID: account),
                try tx.body(messageID: reply, accountID: account),
                try tx.messageIDsWithoutBody(threadID: "t1", accountID: account),
                try tx.unenrichedBodyMessageIDs(threadID: "t1", accountID: account)
            )
        }
        #expect(stored.0.map { EmailAddress.parseList($0.sender) } == [me])
        #expect(stored.0?.rfcMessageID == "<L1@example.com>")
        #expect(stored.1?.html == "<p>Sent words</p>")
        // Opening the conversation fetches only what Gmail sent.
        #expect(stored.2 == ["m1"] && stored.3.isEmpty)
    }

    @Test func aProvisionalSendOutlivesResyncAndEvictionAndLaunchClearsOnlyStrays() async throws {
        let cache = try MailCache.inMemory()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let (queued, stray) = (LocalSend.messageID(localDraftID: "L1"), LocalSend.messageID(localDraftID: "L2"))
        try await cache.write { tx in
            try tx.upsertMessages([update("m1", thread: "t1", labels: [])])
            try tx.rebuildThreads(["t1"], accountID: account)
            for id in ["L1", "L2"] {
                try tx.insertLocalDraft(LocalDraft(id: id, accountID: account, kind: .new, rfcMessageID: "<\(id)@example.com>", now: now))
                _ = try tx.enqueueSend(localDraftID: id, now: now, notBefore: now, rendering: rendering)
            }
            // A fault that ended L2's send and left its message behind.
            try tx.db.execute(sql: "UPDATE localDraft SET state = ? WHERE id = 'L2'", arguments: [LocalDraft.State.editing.rawValue])
        }
        // Gmail can't refetch their bodies or list them in a full resync.
        #expect(try await cache.evictionCandidates(keeping: [], now: now).map(\.thread.threadID) == ["t1"])
        try await cache.write { tx in _ = try tx.deleteMessages(notIn: ["m1"], accountID: account) }
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: account) } == ["m1", queued, stray])

        try await cache.write { try $0.requeueInterruptedActions(accountID: account) }
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: account) } == ["m1", queued])
        #expect(try await threadIDs(cache, SystemLabel.sent) == [queued])
    }

    @Test func draftRowsClaimInTheirOwnLaneAndInOrderPerDraft() async throws {
        let cache = try MailCache.inMemory()
        // A whole millisecond, which the store keeps exactly. Separate `.now`
        // calls can land inside one stored millisecond and compare out of order.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try await cache.write { tx in
            try tx.upsertMessages([update("m1", thread: "t1", labels: [SystemLabel.inbox])])
            try tx.rebuildThreads(["t1"], accountID: account)
            for id in ["L1", "L2"] {
                try tx.insertLocalDraft(LocalDraft(id: id, accountID: account, kind: .new, rfcMessageID: "<\(id)@example.com>", now: now))
            }
            _ = try tx.enqueue(.modifyThreads, accountID: account, threadIDs: ["t1"], remove: [SystemLabel.inbox], now: now, notBefore: now)
            try tx.enqueueSave(localDraftID: "L1", now: now, notBefore: now)
            #expect(try tx.claimDueActions(accountID: account, now: now, lane: .compose).map(\.localDraftID) == ["L1"])
            // A send queued while the save uploads waits for it.
            _ = try tx.enqueueSend(localDraftID: "L1", now: now, notBefore: now, rendering: rendering)
            try tx.enqueueSave(localDraftID: "L2", now: now, notBefore: now)
        }

        let compose = try await cache.write { tx in try tx.claimDueActions(accountID: account, now: now, lane: .compose) }
        let labels = try await cache.write { tx in try tx.claimDueActions(accountID: account, now: now) }
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
    historyID: Int64 = 100,
    in accountID: String = account
) -> CacheTransaction.MessageUpdate {
    let record = MessageRecord(
        accountID: accountID, id: id, threadID: thread, historyID: historyID,
        date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60),
        snippet: "", sender: "Sender <s@example.com>", recipients: "r@example.com",
        cc: nil, subject: "Subject", sizeEstimate: 1
    )
    return .init(record: record, labelIDs: labels)
}

private func rendering(_ draft: LocalDraft) -> LocalSend.Rendering {
    LocalSend.Rendering(sender: EmailAddress(name: "Me", address: "me@example.com"), html: nil, plainText: draft.body.plainText())
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
