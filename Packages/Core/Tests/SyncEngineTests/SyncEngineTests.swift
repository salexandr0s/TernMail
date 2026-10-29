import Foundation
import GmailAPI
import MailStore
import MessageContent
import os
import Testing
@testable import SyncEngine

private let account = "acct"
private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct ActionQueueTests {
    @Test func unreadableMutationResponsesKeepTheActionAndItsUndo() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        let receipt = try #require(try await engine.perform(.archive, threadIDs: ["t1"]))
        await gmail.failNextChange(with: .decoding("Batch response has no boundary"))
        clock.advance(3)
        await engine.sendDueActions()
        #expect(try await pendingActions(cache).map(\.state) == [.queued])
        try await engine.undo(receipt)
        await engine.sendDueActions()
        #expect(await gmail.changes == [
            Change("modifyThreads", ["t1"], remove: [SystemLabel.inbox]),
            Change("batchModify", ["m1"], add: [SystemLabel.inbox]),
        ])
    }

    @Test func retriesBlockLaterChangesOnlyOnTheSameThread() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])])
        try await engine.perform(.archive, threadIDs: ["t1"])
        clock.advance(3)
        await gmail.failNextChange(with: .rateLimited)
        await engine.sendDueActions()
        try await engine.perform(.markUnread, threadIDs: ["t1"])
        try await engine.perform(.markUnread, threadIDs: ["t2"])
        clock.advance(3)
        await engine.sendDueActions()
        #expect(try await pendingActions(cache).map(\.state) == [.sent, .queued, .sent])
        await engine.sendDueActions()
        #expect(await gmail.changes == [
            Change("modifyThreads", ["t1"], remove: [SystemLabel.inbox]),
            Change("modifyThreads", ["t1"], remove: [SystemLabel.inbox]),
            Change("modifyThreads", ["t2"], add: [SystemLabel.unread]),
            Change("modifyThreads", ["t1"], add: [SystemLabel.unread]),
        ])
    }

    @Test func independentThreadChangesShareOneDeliveryBatch() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])])
        try await engine.perform(.archive, threadIDs: ["t1", "t2"])
        clock.advance(3)
        await engine.sendDueActions()
        #expect(await gmail.changes == [Change("modifyThreads", ["t1", "t2"], remove: [SystemLabel.inbox])])
        #expect(try await pendingActions(cache).map(\.state) == [.sent, .sent])
    }

    @Test func undoAfterConfirmationRestoresUncachedMessagesFromTheSendSnapshot() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        await gmail.setThread(try decode(GmailThread.self, """
            {"id":"t1","messages":[\(try encodedMessage("m1", thread: "t1")),\(try encodedMessage("m2", thread: "t1")),\(try encodedMessage("m3", thread: "t1", labels: [SystemLabel.sent]))]}
            """))
        let receipt = try #require(try await engine.perform(.archive, threadIDs: ["t1"]))
        clock.advance(3)
        await engine.sendDueActions()
        clock.advance(1)
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId":"250"}"#))
        try await engine.sync()
        #expect(try await pendingActions(cache).isEmpty)
        try await engine.undo(receipt)
        await engine.sendDueActions()
        #expect(await gmail.changes.last == Change("batchModify", ["m1", "m2"], add: [SystemLabel.inbox]))
    }

    @Test func undoTrashKeepsMessagesThatWereAlreadyInTrash() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t1", [SystemLabel.trash])])
        let action = try #require(try await engine.perform(.trash, threadIDs: ["t1"]))
        clock.advance(3)
        await engine.sendDueActions()
        try await engine.undo(action)
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        #expect(try await threadIDs(cache, SystemLabel.trash) == ["t1"])
        await engine.sendDueActions()
        await engine.sendDueActions()
        #expect(await gmail.changes == [
            Change("trash", ["t1"]), Change("untrash", ["t1"]), Change("batchModify", ["m2"], add: [SystemLabel.trash]),
        ])
    }

    @Test func rejectedCredentialsKeepTheChangeForReauthentication() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        try await engine.perform(.archive, threadIDs: ["t1"])
        await gmail.failNextChange(with: .unauthorized)
        clock.advance(3)
        await engine.sendDueActions()
        #expect(try await pendingActions(cache).map(\.state) == [.queued])
        #expect(try await threadIDs(cache, SystemLabel.inbox).isEmpty)
    }

    @Test func partialFailuresKeepIndependentRetriesAndUndoOnlyAcceptedTargets() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [
            ("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox]), ("m3", "t3", [SystemLabel.inbox]),
        ])
        await gmail.setChangeErrors(["t1": .rateLimited, "t2": .http(status: 403, reason: "forbidden")])
        let action = try #require(try await engine.perform(.archive, threadIDs: ["t1", "t2", "t3"]))
        clock.advance(3)
        await engine.sendDueActions()
        let rows = try await pendingActions(cache)
        #expect(rows.map(\.threadIDs) == [["t1"], ["t3"]])
        #expect(rows.map(\.state) == [.queued, .sent])
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t2"])
        try await engine.undo(action)
        await engine.sendDueActions()
        let inverses = await gmail.changes.filter { $0.kind == "batchModify" }
        #expect(inverses.map(\.ids) == [["m1", "m3"]])
        // A repeated undo cannot enqueue another inverse after confirmation.
        try await engine.undo(action)
        #expect(try await pendingActions(cache).filter { $0.state == .queued }.isEmpty)
    }

    @Test func undoAfterCrashCompensatesAnInterruptedFirstSend() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        let action = try #require(try await engine.perform(.archive, threadIDs: ["t1"]))
        clock.advance(3)
        // Claiming is durable; the process can quit after Gmail sees this send.
        let date = clock.now()
        _ = try await cache.write { tx in try tx.claimDueActions(accountID: account, now: date) }
        try await cache.write { tx in try tx.requeueInterruptedActions(accountID: account) }
        try await engine.undo(action)
        await engine.sendDueActions()
        #expect(await gmail.changes == [Change("batchModify", ["m1"], add: [SystemLabel.inbox])])
    }

    @Test func undoDuringTheHoldSendsNothing() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])

        let action = try #require(try await engine.perform(.archive, threadIDs: ["t1"]))
        #expect(try await threadIDs(cache, SystemLabel.inbox).isEmpty)
        try await engine.undo(action)
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])

        clock.advance(5)
        await engine.sendDueActions()
        #expect(await gmail.changes.isEmpty)
        #expect(try await pendingActions(cache).isEmpty)
    }

    @Test func undoAfterSendRestoresOnlyTheMessagesThatChanged() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [
            ("m1", "t1", [SystemLabel.inbox, SystemLabel.unread]),
            ("m2", "t1", [SystemLabel.sent]),
        ])

        let action = try #require(try await engine.perform(.archive, threadIDs: ["t1"]))
        clock.advance(3)
        await engine.sendDueActions()
        #expect(await gmail.changes == [Change("modifyThreads", ["t1"], remove: [SystemLabel.inbox])])
        #expect(try await pendingActions(cache).map(\.state) == [.sent])

        try await engine.undo(action)
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        await engine.sendDueActions()
        #expect(await gmail.changes.last == Change("batchModify", ["m1"], add: [SystemLabel.inbox]))
    }

    @Test func undoAfterTrashSendsUntrash() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])

        let action = try #require(try await engine.perform(.trash, threadIDs: ["t1"]))
        #expect(try await threadIDs(cache, SystemLabel.trash) == ["t1"])
        #expect(try await threadIDs(cache, SystemLabel.inbox).isEmpty)
        clock.advance(3)
        await engine.sendDueActions()

        try await engine.undo(action)
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        #expect(try await threadIDs(cache, SystemLabel.trash).isEmpty)
        await engine.sendDueActions()
        #expect(await gmail.changes == [Change("trash", ["t1"]), Change("untrash", ["t1"])])
    }

    @Test func undoAfterAFailedAttemptDropsTheRetry() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])

        let action = try #require(try await engine.perform(.archive, threadIDs: ["t1"]))
        clock.advance(3)
        // The request reaches Gmail but the response is lost.
        await gmail.failNextChange(with: .server(status: 503))
        await engine.sendDueActions()
        try await engine.undo(action)

        clock.advance(600)
        await engine.sendDueActions()
        await engine.sendDueActions()
        #expect(await gmail.changes == [
            Change("modifyThreads", ["t1"], remove: [SystemLabel.inbox]),
            Change("batchModify", ["m1"], add: [SystemLabel.inbox]),
        ])
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
    }

    @Test func undoDuringASendQueuesTheInverseBehindIt() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])

        let action = try #require(try await engine.perform(.archive, threadIDs: ["t1"]))
        clock.advance(3)
        await gmail.holdNextChange()
        let sending = Task { await engine.sendDueActions() }
        while await !gmail.isHolding { await Task.yield() }

        try await engine.undo(action)
        // The inverse can't overtake the request in flight.
        #expect(await engine.sendDueActions() == 0)
        await gmail.release()
        _ = await sending.value

        #expect(try await pendingActions(cache).map(\.kind) == [.modifyMessages])
        await engine.sendDueActions()
        #expect(await gmail.changes == [
            Change("modifyThreads", ["t1"], remove: [SystemLabel.inbox]),
            Change("batchModify", ["m1"], add: [SystemLabel.inbox]),
        ])
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
    }
}

@Suite struct SyncPassTests {
    @Test func resyncDoesNotPruneNewerMessagesLoadedAfterItsListings() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        await gmail.expireHistory()
        await gmail.add(try gmailMessage("m1", thread: "t1", labels: [SystemLabel.inbox], historyID: 150), inInbox: true)
        await gmail.setThread(try decode(GmailThread.self, """
            {"id":"t1","messages":[\(try encodedMessage("m1", thread: "t1", historyID: 150)),\(try encodedMessage("m2", thread: "t1", historyID: 250))]}
            """))
        await gmail.holdNextMetadata()
        let syncing = Task { try await engine.sync() }
        while await !gmail.isHoldingMetadata { await Task.yield() }
        try await engine.openThread("t1")
        await gmail.releaseMetadata()
        try await syncing.value
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1", "m2"])
        #expect(try await cache.syncState(accountID: account)?.historyID == 200)
    }

    @Test func staleThreadNotFoundDoesNotDeleteMessagesIngestedDuringTheRequest() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        await gmail.holdNextThread()
        let loading = Task { try await engine.openThread("t1") }
        while await !gmail.isHoldingThread { await Task.yield() }
        await gmail.add(try gmailMessage("m2", thread: "t1", labels: [SystemLabel.inbox], historyID: 150))
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId":"160","history":[{"id":"150","messagesAdded":[{"message":{"id":"m2","threadId":"t1"}}]}]}"#))
        try await engine.sync()
        await gmail.releaseThread()
        try await loading.value
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m2"])
    }

    @Test func threadLoadPreservesLaterUnreadIntentAndConcurrentDeletions() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox, SystemLabel.unread]), ("m2", "t1", [SystemLabel.inbox])], cursor: 100)
        await gmail.setThread(try decode(GmailThread.self, """
            {"id":"t1","messages":[\(try encodedMessage("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread])),\(try encodedMessage("m2", thread: "t1"))]}
            """))
        await gmail.holdNextThread()
        let loading = Task { try await engine.openThread("t1") }
        while await !gmail.isHoldingThread { await Task.yield() }
        try await engine.perform(.markUnread, threadIDs: ["t1"])
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId":"120","history":[{"id":"110","messagesDeleted":[{"message":{"id":"m2","threadId":"t1"}}]}]}"#))
        try await engine.sync()
        await gmail.releaseThread()
        try await loading.value
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1"])
        #expect(try await cache.read { tx in try tx.thread(id: "t1", accountID: account)?.isUnread } == true)
    }

    @Test func textStoredAsAnAttachmentLoadsWithoutDownloadingAttachedFiles() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        await gmail.setThread(try decode(GmailThread.self, #"""
            {"id":"t1","messages":[{"id":"m1","threadId":"t1","historyId":"200","labelIds":["INBOX"],
            "payload":{"mimeType":"multipart/mixed","parts":[
              {"mimeType":"text/plain","headers":[{"name":"Content-Type","value":"text/plain; charset=ISO-8859-1"}],"body":{"attachmentId":"body"}},
              {"partId":"1","mimeType":"text/plain","filename":"notes.txt","body":{"attachmentId":"file","size":5}}
            ]}}]}
            """#))
        await gmail.setAttachment("body", data: try #require("Café".data(using: .isoLatin1)))
        try await engine.openThread("t1")
        for try await detail in cache.thread(accountID: account, threadID: "t1") {
            #expect(detail?.messages.first?.body?.plainText == "Café")
            // The file is listed for Quick Look and Save, but not downloaded.
            #expect(detail?.messages.first?.attachments.map(\.filename) == ["notes.txt"])
            break
        }
        #expect(await gmail.attachmentRequests == ["body"])
    }

    @Test func emptyHistoryRefreshesLabelsAndFailedDetailsPreserveTheCache() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [], cursor: 100)
        let label = try decode(GmailLabel.self, #"{"id":"label1","name":"Renamed","type":"user","threadsUnread":3}"#)
        await gmail.setLabels([label])
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId":"120"}"#))
        try await engine.sync()
        let saved = try await cache.read { tx in try tx.labels(accountID: account) }
        #expect(saved.first?.name == "Renamed")
        #expect(saved.first?.threadsUnread == 3)
        await gmail.failLabelDetails(with: .rateLimited)
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId":"130"}"#))
        await #expect(throws: GmailError.rateLimited) { try await engine.sync() }
        #expect(try await cache.read { tx in try tx.labels(accountID: account) } == saved)
        #expect(try await cache.syncState(accountID: account)?.historyID == 120)
    }

    @Test func recentListingContinuesPastTheInboxCap() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        var pages: [MessageListPage] = []
        for page in 0..<10 {
            let refs = (0..<500).map { #"{"id":"old-\#(page)-\#($0)","threadId":"old"}"# }.joined(separator: ",")
            pages.append(try decode(MessageListPage.self, #"{"messages":[\#(refs)],"nextPageToken":"next"}"#))
        }
        pages.append(try decode(MessageListPage.self, #"{"messages":[{"id":"tail","threadId":"tail"}]}"#))
        await gmail.setRecentPages(pages)
        await gmail.add(try gmailMessage("tail", thread: "tail", labels: [], historyID: 150))
        try await engine.sync()
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["tail"])
    }

    @Test func fullSyncKeepsDraftsOutsideTheListedMail() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try gmailMessage("old-draft", thread: "t9", labels: [SystemLabel.draft], historyID: 150))
        await gmail.addDraft("D9", messageID: "old-draft", threadID: "t9")
        try await engine.sync()
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["old-draft"])
        #expect(try await cache.read { tx in try tx.draft(messageID: "old-draft", accountID: account) }?.id == "D9")
    }

    @Test func stopWaitsForDatabaseWritesAlreadyInFlight() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let (entered, signal) = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        let didStop = OSAllocatedUnfairLock(initialState: false)
        let writing = Task {
            try await engine.write { tx in
                signal.yield(())
                release.wait()
                try tx.saveCursor(historyID: 100, accountID: account)
            }
        }
        for await _ in entered { break }
        let stopping = Task { await engine.stop(); didStop.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(25))
        #expect(!didStop.withLock { $0 })
        release.signal()
        try await writing.value
        await stopping.value
        #expect(try await cache.syncState(accountID: account)?.historyID == 100)
    }

    @Test(arguments: [
        #"{"historyId":"bad"}"#,
        #"{"historyId":"120","history":[{"id":"bad","labelsRemoved":[{"message":{"id":"m1","threadId":"t1"},"labelIds":["INBOX"]}]}]}"#,
    ])
    func malformedHistoryDoesNotAdvanceTheCursor(_ json: String) async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        await gmail.queueHistory(try decode(HistoryPage.self, json))
        await #expect(throws: SyncError.invalidHistoryID) { try await engine.sync() }
        #expect(try await cache.syncState(accountID: account)?.historyID == 100)
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
    }

    @Test func invalidMetadataAndAbsentBatchPartsFailThePass() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])], cursor: 100)
        let page = try decode(HistoryPage.self, #"{"historyId":"120","history":[{"id":"110","messagesAdded":[{"message":{"id":"m2","threadId":"t2"}}]}]}"#)
        await gmail.add(try decode(GmailMessage.self, #"{"id":"m2","threadId":"t2","historyId":"bad"}"#))
        await gmail.queueHistory(page)
        await #expect(throws: SyncError.invalidHistoryID) { try await engine.sync() }
        #expect(try await cache.syncState(accountID: account)?.historyID == 100)
        await gmail.omitMetadata(["m2"])
        await gmail.queueHistory(page)
        await #expect(throws: GmailError.missingBatchPart) { try await engine.sync() }
        #expect(try await cache.syncState(accountID: account)?.historyID == 100)
    }

    @Test func resyncRefreshesTargetsQueuedWhileMetadataIsInFlight() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox, SystemLabel.unread])], cursor: 100)
        await gmail.expireHistory()
        await gmail.add(try gmailMessage("m1", thread: "t1", labels: [SystemLabel.inbox], historyID: 150), inInbox: true)
        await gmail.add(try gmailMessage("m2", thread: "t2", labels: [SystemLabel.unread], historyID: 160))
        await gmail.holdNextMetadata()
        let syncing = Task { try await engine.sync() }
        while await !gmail.isHoldingMetadata { await Task.yield() }
        try await engine.perform(.markRead, threadIDs: ["t2"])
        await gmail.releaseMetadata()
        try await syncing.value
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        #expect(await gmail.metadataRequests.contains(["m2"]))
    }

    @Test func failedFullSyncDoesNotPublishPartialMessages() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        for index in 0...100 {
            await gmail.add(try gmailMessage("m\(index)", thread: "t\(index)", labels: [SystemLabel.inbox], historyID: 150), inInbox: true)
        }
        await gmail.setMetadataErrors(["m100": .server(status: 503)])
        await #expect(throws: GmailError.server(status: 503)) { try await engine.sync() }
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) }.isEmpty)
        #expect(try await cache.syncState(accountID: account) == nil)
    }

    @Test func historyPassAppliesChangesAndDropsConfirmedActions() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [
            ("m1", "t1", [SystemLabel.inbox, SystemLabel.unread]),
            ("m3", "t3", [SystemLabel.inbox]),
        ], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t3"])
        clock.advance(3)
        await engine.sendDueActions()
        clock.advance(1)

        await gmail.add(try gmailMessage("m2", thread: "t2", labels: [SystemLabel.inbox], historyID: 115, minutes: 10))
        await gmail.queueHistory(try decode(HistoryPage.self, """
            {"historyId": "120", "history": [
              {"id": "101", "labelsRemoved": [{"message": {"id": "m1", "threadId": "t1"}, "labelIds": ["UNREAD"]}]},
              {"id": "102", "messagesAdded": [{"message": {"id": "m2", "threadId": "t2"}}]},
              {"id": "103", "messagesDeleted": [{"message": {"id": "m3", "threadId": "t3"}}]}
            ]}
            """))
        try await engine.sync()

        #expect(try await cache.syncState(accountID: account)?.historyID == 120)
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t2", "t1"])
        #expect(try await cache.read { tx in try tx.thread(id: "t1", accountID: account)?.isUnread } == false)
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1", "m2"])
        #expect(try await pendingActions(cache).isEmpty)

        // A page with no records still moves the cursor.
        await gmail.queueHistory(try decode(HistoryPage.self, #"{"historyId": "130"}"#))
        try await engine.sync()
        #expect(try await cache.syncState(accountID: account)?.historyID == 130)
    }

    @Test func expiredCursorResyncRefreshesMessagesPendingActionsTarget() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [
            ("m1", "t1", [SystemLabel.inbox]),
            ("m7", "t7", [SystemLabel.inbox]),
            ("m8", "t8", [SystemLabel.inbox, SystemLabel.unread]),
            ("m9", "t9", [SystemLabel.inbox]),
        ], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t7"])
        try await engine.perform(.markRead, threadIDs: ["t8"])

        // While the cursor was lost, m8 was archived elsewhere and m7 deleted.
        await gmail.expireHistory()
        await gmail.add(try gmailMessage("m1", thread: "t1", labels: [SystemLabel.inbox], historyID: 150), inInbox: true)
        await gmail.add(try gmailMessage("m8", thread: "t8", labels: [SystemLabel.unread], historyID: 160))
        try await engine.sync()

        #expect(try await cache.syncState(accountID: account)?.historyID == 200)
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1", "m8"])
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
    }

    @Test func threadLoadDoesNotRestoreAMessageHistoryDeleted() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [
            ("m1", "t1", [SystemLabel.inbox]),
            ("m2", "t1", [SystemLabel.inbox]),
        ], cursor: 100)
        await gmail.queueHistory(try decode(HistoryPage.self, """
            {"historyId": "120", "history": [
              {"id": "110", "messagesDeleted": [{"message": {"id": "m2", "threadId": "t1"}}]}
            ]}
            """))
        try await engine.sync()

        // Tombstones must survive a large deletion pass and subsequent empty polls.
        let deletions = (0...10_000).map { #"{"message":{"id":"gone-\#($0)","threadId":"gone"}}"# }.joined(separator: ",")
        await gmail.queueHistory(try decode(HistoryPage.self, """
            {"historyId":"140","history":[{"id":"130","messagesDeleted":[\(deletions)]}]}
            """))
        try await engine.sync()
        try await engine.sync()

        // A thread response from before the deletion arrives afterwards.
        await gmail.setThread(try decode(GmailThread.self, """
            {"id": "t1", "messages": [\(try encodedMessage("m1", thread: "t1")), \(try encodedMessage("m2", thread: "t1"))]}
            """))
        try await engine.openThread("t1")
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1"])
    }

    @Test func missingMetadataAndMissingThreadsRemoveCachedMessages() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t2", [SystemLabel.inbox])], cursor: 100)
        await gmail.queueHistory(try decode(HistoryPage.self, """
            {"historyId":"120","history":[{"id":"110","messagesAdded":[{"message":{"id":"m1","threadId":"t1"}}]}]}
            """))
        try await engine.sync()
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m2"])
        try await engine.openThread("t2")
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) }.isEmpty)
    }
}

// MARK: Fixtures

@Suite struct ComposeQueueTests {
    @Test func savesCreateOneDraftThenUpdateIt() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        try await engine.saveDraft(draft.id)
        #expect(await engine.sendDueDrafts() == 1)
        var content = draft.content
        content.subject = "Re: Lunch on Friday"
        content.cc = [EmailAddress(address: "Pat")]
        try await engine.saveDraft(draft.id, content: content)
        #expect(await engine.sendDueDrafts() == 1)

        #expect(await gmail.draftCalls == ["create", "update D1"])
        let stored = try #require(try await cache.read { tx in try tx.localDraft(id: draft.id) })
        #expect(stored.gmailDraftID == "D1")
        #expect(stored.savedRevision == stored.revision)
        // The update replaced the first message, so the thread holds one.
        let messages = try await cache.read { tx in try tx.messages(threadID: "thread1", accountID: account) }
        #expect(messages.map(\.id) == ["msg2"])
        let raw = String(decoding: try #require(await gmail.uploads.last).raw, as: UTF8.self)
        #expect(raw.contains("Subject: Re: Lunch on Friday"))
        #expect(raw.contains("In-Reply-To: <original@example.com>"))
        #expect(!raw.contains("Cc:"))
        #expect(stored.cc == content.cc)
        #expect(try await pendingActions(cache).isEmpty)
    }

    @Test func undoSendCancelsBeforeTheDelayEnds() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        #expect(try await engine.sendDraft(draft.id, delay: 10))
        #expect(await engine.sendDueDrafts() == 0)
        #expect(try await engine.undoSend(draft.id))
        clock.advance(11)
        #expect(await engine.sendDueDrafts() == 0)

        #expect(await gmail.draftCalls.isEmpty)
        let stored = try await cache.read { tx in try tx.localDraft(id: draft.id) }
        #expect(stored?.state == .editing)
    }

    @Test func sendUploadsAttachmentsAndRemovesTheDraft() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        let source = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString).txt")
        try Data("agenda".utf8).write(to: source)
        let attachment = try #require(try await engine.attachFile(at: source, to: draft.id))
        #expect(attachment.mimeType == "text/plain" && attachment.size == 6)
        // The draft keeps its own copy.
        try FileManager.default.removeItem(at: source)
        let folder = await engine.outgoingDirectory.appending(path: draft.id, directoryHint: .isDirectory)
        try await engine.sendDraft(draft.id, delay: 10)
        clock.advance(10)
        #expect(await engine.sendDueDrafts() == 1)

        // A draft that never reached Gmail is saved before it's sent.
        #expect(await gmail.draftCalls == ["create", "send D1"])
        let raw = String(decoding: try #require(await gmail.uploads.last).raw, as: UTF8.self)
        #expect(raw.contains("notes-"))
        #expect(try await cache.read { tx in try tx.localDraft(id: draft.id) } == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(try await threadIDs(cache, SystemLabel.sent) == ["thread1"])
        await engine.stop()
        var events: [SyncEvent] = []
        for await event in engine.events { events.append(event) }
        #expect(events == [.draftSent(localDraftID: draft.id)])
    }

    @Test func attachingMoreThanGmailAcceptsIsRefused() async throws {
        let (engine, cache, _, _) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        await #expect(throws: ComposeError.fileTooLarge("large.bin")) {
            try await engine.attachData(Data(count: 26_000_000), filename: "large.bin", mimeType: "application/octet-stream", to: draft.id)
        }
        #expect(try await cache.read { tx in try tx.outgoingAttachments(localDraftID: draft.id) }.isEmpty)
        let folder = await engine.outgoingDirectory.appending(path: draft.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).isEmpty)
    }

    @Test func aRepeatedSendThatFindsTheDraftGoneCountsAsSent() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        try await engine.saveDraft(draft.id)
        await engine.sendDueDrafts()
        // Gmail sends it, but the response is lost.
        await gmail.failNextDraftCall("send", with: .transport(.networkConnectionLost), afterApplying: true)
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()
        #expect(try await pendingActions(cache).first?.lastError != nil)
        clock.advance(10)
        await engine.sendDueDrafts()

        #expect(await gmail.draftCalls == ["create", "send D1", "send D1"])
        #expect(try await cache.read { tx in try tx.localDraft(id: draft.id) } == nil)
        #expect(try await pendingActions(cache).isEmpty)
    }

    @Test func aFirstSendThatFindsTheDraftGoneReturnsItToEditing() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        try await engine.saveDraft(draft.id)
        await engine.sendDueDrafts()
        await gmail.deleteDraftElsewhere("D1")
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()

        let stored = try #require(try await cache.read { tx in try tx.localDraft(id: draft.id) })
        #expect(stored.state == .editing)
        #expect(stored.gmailDraftID == nil)
        #expect(stored.sendError == "This draft was sent or deleted in another app.")
        #expect(try await pendingActions(cache).isEmpty)
    }

    @Test func aLostCreateResponseAdoptsTheDraftGmailMade() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        await gmail.failNextDraftCall("create", with: .transport(.timedOut), afterApplying: true)
        try await engine.saveDraft(draft.id)
        await engine.sendDueDrafts()
        await gmail.setDraftSearch("rfc822msgid:draft1@example.com", ids: ["D1"])
        clock.advance(10)
        await engine.sendDueDrafts()

        #expect(await gmail.draftCalls == ["create", "update D1"])
        let stored = try await cache.read { tx in try tx.localDraft(id: draft.id) }
        #expect(stored?.gmailDraftID == "D1")
    }

    @Test func aRefusedSendReturnsTheDraftToEditingWithAMessage() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        await gmail.failNextDraftCall("create", with: .http(status: 400, reason: "invalidArgument"))
        try await engine.sendDraft(draft.id, delay: 0)
        await engine.sendDueDrafts()

        let stored = try await cache.read { tx in try tx.localDraft(id: draft.id) }
        #expect(stored?.state == .editing)
        #expect(stored?.sendError == "Gmail didn't send this message. Check the recipients and try again.")
        #expect(try await pendingActions(cache).isEmpty)
    }
}

@Suite struct DraftImportTests {
    @Test func replyBuildsOnTheCachedMessage() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let original = MessageRecord(
            accountID: account, id: "m1", threadID: "t1", historyID: 1, date: baseDate, snippet: "",
            sender: "Ana <ana@example.com>", recipients: "Me <me@example.com>", cc: nil, subject: "Lunch",
            sizeEstimate: 0, rfcMessageID: "<lunch@example.com>"
        )
        try await cache.write { tx in
            try tx.rebuildThreads(try tx.upsertMessages([.init(record: original, labelIDs: [SystemLabel.inbox])]), accountID: account)
            try tx.saveBodies([MessageBodyRecord(accountID: account, messageID: "m1", html: nil, plainText: "Friday?", fetchedAt: baseDate)])
        }
        let draft = try await engine.startReply(.reply, to: "m1")

        #expect(draft.to.map(\.address) == ["ana@example.com"])
        #expect(draft.subject == "Re: Lunch")
        #expect(draft.threadID == "t1")
        #expect(draft.inReplyTo == "<lunch@example.com>")
        #expect(draft.references == ["<lunch@example.com>"])
        #expect(draft.quotedPlainText?.contains("Friday?") == true)
        #expect(await gmail.metadataRequests.isEmpty)
    }

    @Test func forwardFetchesTheOriginalAndCopiesItsFiles() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try decode(GmailMessage.self, #"""
            {"id":"m1","threadId":"t1","historyId":"200","labelIds":["INBOX"],
            "payload":{"mimeType":"multipart/mixed","headers":[
              {"name":"From","value":"Ana <ana@example.com>"},{"name":"Subject","value":"Agenda"},
              {"name":"Message-ID","value":"<agenda@example.com>"}],
            "parts":[
              {"partId":"0","mimeType":"text/plain","body":{"data":"U2VlIGF0dGFjaGVk"}},
              {"partId":"1","mimeType":"text/plain","filename":"agenda.txt","body":{"attachmentId":"a1","size":5}}
            ]}}
            """#))
        await gmail.setAttachment("a1", data: Data("items".utf8))
        let draft = try await engine.startReply(.forward, to: "m1")

        #expect(draft.subject == "Fwd: Agenda")
        #expect(draft.to.isEmpty)
        #expect(draft.quotedPlainText?.contains("See attached") == true)
        let files = try await cache.read { tx in try tx.outgoingAttachments(localDraftID: draft.id) }
        #expect(files.map(\.filename) == ["agenda.txt"])
        let folder = await engine.outgoingDirectory
        #expect(try Data(contentsOf: folder.appending(path: try #require(files.first).path)) == Data("items".utf8))
    }

    @Test func receivedAttachmentsDownloadOnceThroughTheirPartID() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.add(try decode(GmailMessage.self, #"""
            {"id":"m1","threadId":"t1","historyId":"200","labelIds":["INBOX"],
            "payload":{"mimeType":"multipart/mixed","headers":[{"name":"Subject","value":"Files"}],
            "parts":[
              {"partId":"0","mimeType":"text/plain","body":{"data":"SGk="}},
              {"partId":"1","mimeType":"text/plain","filename":"../notes.txt","body":{"attachmentId":"a1","size":5}},
              {"partId":"2","mimeType":"text/plain","filename":"small.txt","body":{"data":"c21hbGw=","size":5}}
            ]}}
            """#))
        await gmail.setAttachment("a1", data: Data("notes".utf8))
        let directory = FileManager.default.temporaryDirectory.appending(path: "TernReceived-\(UUID().uuidString)")
        func record(_ partID: String, _ filename: String, attachmentID: String?) -> AttachmentRecord {
            AttachmentRecord(accountID: account, messageID: "m1", partID: partID, attachmentID: attachmentID,
                             filename: filename, mimeType: "text/plain", size: 5, isInline: false)
        }

        // The stored ID went stale, so the message is fetched again for the current one.
        let notes = try await engine.downloadAttachment(record("1", "../notes.txt", attachmentID: "expired"), into: directory)
        #expect(notes.lastPathComponent == "-notes.txt")
        #expect(notes.deletingLastPathComponent().path.hasPrefix(directory.path))
        #expect(try Data(contentsOf: notes) == Data("notes".utf8))
        // Bytes Gmail put in the payload come from the message itself.
        let small = try await engine.downloadAttachment(record("2", "small.txt", attachmentID: nil), into: directory)
        #expect(try Data(contentsOf: small) == Data("small".utf8))
        // A second open reuses the file.
        await gmail.setAttachment("a1", data: Data("changed".utf8))
        #expect(try await engine.downloadAttachment(record("1", "../notes.txt", attachmentID: "a1"), into: directory) == notes)
        #expect(try Data(contentsOf: notes) == Data("notes".utf8))
    }

    @Test func openingADraftFromAnotherAppImportsItAsSaved() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.addDraft("D7", messageID: "m7", threadID: "t7")
        await gmail.setDraftJSON("D7", draftJSON(messageID: "m7", subject: "Plans", html: #"<p>Hi <b>there</b></p><div class="gmail_quote">Ana wrote:<blockquote>Hello</blockquote></div>"#))
        // The draft table doesn't have it yet, so opening relists Gmail's drafts.
        let opened = try await engine.openDraft(messageID: "m7")
        let draft = opened.draft

        #expect(draft.kind == .edit)
        #expect(draft.gmailDraftID == "D7")
        #expect(draft.subject == "Plans")
        #expect(draft.to.map(\.address) == ["ana@example.com"])
        #expect(draft.body.plainText() == "Hi there")
        #expect(draft.quotedHTML?.contains("gmail_quote") == true)
        #expect(!draft.hasUnsavedChanges)
        #expect(!opened.droppedFormatting)
        #expect(try await engine.openDraft(messageID: "m7").draft == draft)
    }

    @Test func aSaveAfterAnotherAppChangedTheDraftKeepsBothVersions() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.addDraft("D7", messageID: "m7", threadID: "t7")
        await gmail.setDraftJSON("D7", draftJSON(messageID: "m7", subject: "Plans", html: "<p>Hi</p>"))
        let draft = try await engine.openDraft(messageID: "m7").draft
        await gmail.addDraft("D7", messageID: "m8", threadID: "t7")
        await gmail.setDraftJSON("D7", draftJSON(messageID: "m8", subject: "Plans for Friday", html: "<p>Hi all</p>"))
        var content = draft.content
        content.subject = "Plans, mine"
        try await engine.saveDraft(draft.id, content: content)
        await engine.sendDueDrafts()

        // A new draft instead of "update D7", which would overwrite the other app's version.
        #expect(await gmail.draftCalls == ["create"])
        let stored = try await cache.read { tx in try tx.localDraft(id: draft.id) }
        #expect(stored?.gmailDraftID == "D1")
        #expect(try await cache.read { tx in try tx.draft(id: "D7", accountID: account) } != nil)
        await engine.stop()
        var events: [SyncEvent] = []
        for await event in engine.events { events.append(event) }
        #expect(events == [.draftCopied(localDraftID: draft.id)])
    }

    @Test func reopeningAChangedDraftWithUnsavedEditsImportsGmailsCopyBesideIt() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.addDraft("D7", messageID: "m7", threadID: "t7")
        await gmail.setDraftJSON("D7", draftJSON(messageID: "m7", subject: "Plans", html: "<p>Hi</p>"))
        let draft = try await engine.openDraft(messageID: "m7").draft
        var content = draft.content
        content.subject = "Plans, mine"
        try await engine.updateDraft(draft.id, content: content)
        await gmail.addDraft("D7", messageID: "m8", threadID: "t7")
        await gmail.setDraftJSON("D7", draftJSON(messageID: "m8", subject: "Plans for Friday", html: "<p>Hi all</p>"))
        let reopened = try await engine.openDraft(id: "D7").draft

        #expect(reopened.id != draft.id)
        #expect(reopened.gmailDraftID == "D7")
        #expect(reopened.subject == "Plans for Friday")
        let kept = try await cache.read { tx in try tx.localDraft(id: draft.id) }
        #expect(kept?.gmailDraftID == nil)
        #expect(kept?.subject == "Plans, mine")
        #expect(try await pendingActions(cache).map(\.kind) == [.saveDraft])
    }
}

/// A `drafts.get` response in full format with an HTML body.
private func draftJSON(messageID: String, subject: String, html: String) -> String {
    let data = Data(html.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return #"""
        {"id":"D7","message":{"id":"\#(messageID)","threadId":"t7","historyId":"300","labelIds":["DRAFT"],
        "payload":{"mimeType":"text/html","headers":[
          {"name":"To","value":"Ana <ana@example.com>"},{"name":"Subject","value":"\#(subject)"},
          {"name":"Message-ID","value":"<\#(messageID)@example.com>"}],
        "body":{"data":"\#(data)"}}}}
        """#
}

private func makeDraft() -> LocalDraft {
    LocalDraft(
        accountID: account,
        kind: .reply,
        content: DraftContent(
            to: [EmailAddress(name: "Ana", address: "ana@example.com")],
            subject: "Re: Lunch",
            body: ComposeDocument(plainText: "Sounds good.")
        ),
        rfcMessageID: "<draft1@example.com>",
        inReplyTo: "<original@example.com>",
        references: ["<original@example.com>"],
        now: baseDate
    )
}

struct Change: Equatable, CustomStringConvertible {
    let kind: String
    let ids: [String]
    let add: [String]
    let remove: [String]

    init(_ kind: String, _ ids: [String], add: [String] = [], remove: [String] = []) {
        self.kind = kind
        self.ids = ids
        self.add = add
        self.remove = remove
    }

    var description: String { "\(kind) \(ids) +\(add) -\(remove)" }
}

struct ThreadSearch: Equatable, Sendable {
    let query: String?
    let labelIDs: [String]
    let includeSpamTrash: Bool
    let pageToken: String?
}

/// A mailbox in memory: serves listings, metadata and history pages, and
/// records every change sent to it.
actor FakeGmail: GmailService {
    private(set) var changes: [Change] = []
    private var messagesByID: [String: GmailMessage] = [:]
    private var inboxIDs: [String] = []
    private var historyPages: [HistoryPage] = []
    private var labelValues: [GmailLabel] = []
    private var labelError: GmailError?
    private var recentPages: [MessageListPage] = []
    private var historyExpired = false
    private let profileHistoryID = "200"
    private var threadsByID: [String: GmailThread] = [:]
    private var attachments: [String: Data] = [:]
    private(set) var attachmentRequests: [String] = []
    private var nextChangeError: GmailError?
    private var changeErrors: [String: GmailError] = [:]
    private var holdsNextChange = false
    private var held: CheckedContinuation<Void, Never>?
    private var holdsMetadata = false
    private var heldMetadata: CheckedContinuation<Void, Never>?
    private var holdsThread = false
    private var heldThread: CheckedContinuation<Void, Never>?
    private var metadataErrors: [String: GmailError] = [:]
    private var omittedMetadataIDs = Set<String>()
    private(set) var metadataRequests: [[String]] = []

    func add(_ message: GmailMessage, inInbox: Bool = false) {
        messagesByID[message.id] = message
        if inInbox { inboxIDs.append(message.id) }
    }

    func queueHistory(_ page: HistoryPage) { historyPages.append(page) }
    func setRecentPages(_ pages: [MessageListPage]) { recentPages = pages }
    func setLabels(_ labels: [GmailLabel]) { labelValues = labels }
    func failLabelDetails(with error: GmailError) { labelError = error }
    func expireHistory() { historyExpired = true }
    func setThread(_ thread: GmailThread) { threadsByID[thread.id] = thread }
    func setAttachment(_ id: String, data: Data) { attachments[id] = data }
    func attachment(messageID: String, attachmentID: String) throws -> Data {
        attachmentRequests.append(attachmentID)
        guard let data = attachments[attachmentID] else { throw GmailError.notFound }
        return data
    }

    /// The next change is recorded, as if Gmail applied it, then fails with `error`.
    func failNextChange(with error: GmailError) { nextChangeError = error }
    func setChangeErrors(_ errors: [String: GmailError]) { changeErrors = errors }
    func holdNextMetadata() { holdsMetadata = true }
    func holdNextThread() { holdsThread = true }
    var isHoldingThread: Bool { heldThread != nil }
    func releaseThread() { heldThread?.resume(); heldThread = nil }
    var isHoldingMetadata: Bool { heldMetadata != nil }
    func releaseMetadata() { heldMetadata?.resume(); heldMetadata = nil }
    func setMetadataErrors(_ errors: [String: GmailError]) { metadataErrors = errors }
    func omitMetadata(_ ids: Set<String>) { omittedMetadataIDs = ids }

    /// The next change waits until `release()`.
    func holdNextChange() { holdsNextChange = true }
    var isHolding: Bool { held != nil }
    func release() {
        held?.resume()
        held = nil
    }

    private func record(_ change: Change) async throws {
        if holdsNextChange {
            holdsNextChange = false
            await withCheckedContinuation { held = $0 }
        }
        changes.append(change)
        if let error = nextChangeError {
            nextChangeError = nil
            throw error
        }
    }

    func profile() async throws -> GmailProfile {
        try decode(GmailProfile.self, #"{"emailAddress": "me@example.com", "historyId": "\#(profileHistoryID)"}"#)
    }

    func labels() async throws -> [GmailLabel] { labelValues }
    func labels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>] {
        Dictionary(uniqueKeysWithValues: labelValues.filter { ids.contains($0.id) }.map { label in
            (label.id, labelError.map { .failure($0) } ?? Result<GmailLabel, GmailError>.success(label))
        })
    }

    func listMessages(
        query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int
    ) async throws -> MessageListPage {
        if query != nil, !recentPages.isEmpty { return recentPages.removeFirst() }
        let ids = labelIDs.contains(SystemLabel.inbox) ? inboxIDs : []
        let refs = ids.compactMap { messagesByID[$0] }.map { #"{"id": "\#($0.id)", "threadId": "\#($0.threadId)"}"# }
        return try decode(MessageListPage.self, #"{"messages": [\#(refs.joined(separator: ","))]}"#)
    }

    func messages(ids: [String], format: MessageFormat, metadataHeaders: [String]) async throws -> [String: Result<GmailMessage, GmailError>] {
        metadataRequests.append(ids)
        let results = Dictionary(uniqueKeysWithValues: ids.filter { !omittedMetadataIDs.contains($0) }.map { id in
            (id, metadataErrors[id].map { .failure($0) } ?? messagesByID[id].map { .success($0) } ?? Result<GmailMessage, GmailError>.failure(.notFound))
        })
        if holdsMetadata {
            holdsMetadata = false
            await withCheckedContinuation { heldMetadata = $0 }
        }
        return results
    }

    func thread(id: String, format: MessageFormat) async throws -> GmailThread {
        let response = threadsByID[id]
        if holdsThread {
            holdsThread = false
            await withCheckedContinuation { heldThread = $0 }
        }
        guard let thread = response else { throw GmailError.notFound }
        return thread
    }

    // MARK: Search

    private(set) var threadSearches: [ThreadSearch] = []
    /// The thread IDs of each batched `threads.get`, in order.
    private(set) var threadRequests: [[String]] = []
    private(set) var threadRequestHeaders: [String] = []
    private var threadPages: [String: [[String]]] = [:]
    private var holdsThreadList = false
    private var heldThreadList: CheckedContinuation<Void, Never>?

    /// `threads.list` pages for a query, or for a label ID when there's no
    /// query. The page token is the next page's index.
    func setThreadPages(_ key: String, _ pages: [[String]]) { threadPages[key] = pages }
    func holdNextThreadList() { holdsThreadList = true }
    var isHoldingThreadList: Bool { heldThreadList != nil }
    func releaseThreadList() { heldThreadList?.resume(); heldThreadList = nil }

    func listThreads(
        query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int
    ) async throws -> ThreadListPage {
        threadSearches.append(ThreadSearch(query: query, labelIDs: labelIDs, includeSpamTrash: includeSpamTrash, pageToken: pageToken))
        if holdsThreadList {
            holdsThreadList = false
            await withCheckedContinuation { heldThreadList = $0 }
        }
        let pages = threadPages[query ?? labelIDs.joined(separator: ",")] ?? []
        let index = pageToken.flatMap(Int.init) ?? 0
        let ids = index < pages.count ? pages[index] : []
        let next = index + 1 < pages.count ? #""nextPageToken": "\#(index + 1)", "# : ""
        let threads = ids.map { #"{"id": "\#($0)"}"# }.joined(separator: ",")
        return try decode(ThreadListPage.self, #"{\#(next)"threads": [\#(threads)]}"#)
    }

    /// Answers from `setThread`, like `thread(id:format:)`.
    func threads(ids: [String], format: MessageFormat, metadataHeaders: [String]) async throws -> [String: Result<GmailThread, GmailError>] {
        threadRequests.append(ids)
        threadRequestHeaders = metadataHeaders
        return Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, threadsByID[id].map { .success($0) } ?? Result<GmailThread, GmailError>.failure(.notFound))
        })
    }

    func history(startHistoryID: String, pageToken: String?) async throws -> HistoryPage {
        if historyExpired { throw GmailError.notFound }
        guard !historyPages.isEmpty else { return try decode(HistoryPage.self, #"{"historyId": "\#(startHistoryID)"}"#) }
        return historyPages.removeFirst()
    }

    func modifyThreads(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws -> [String: GmailError] {
        try await record(Change("modifyThreads", ids, add: addLabelIDs, remove: removeLabelIDs))
        return changeErrors.filter { ids.contains($0.key) }
    }

    func trashThreads(ids: [String]) async throws -> [String: GmailError] {
        try await record(Change("trash", ids))
        return [:]
    }

    func untrashThreads(ids: [String]) async throws -> [String: GmailError] {
        try await record(Change("untrash", ids))
        return [:]
    }

    func batchModifyMessages(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws {
        try await record(Change("batchModify", ids, add: addLabelIDs, remove: removeLabelIDs))
    }

    // MARK: Labels

    /// Label calls in order, such as "create Trips", "patch Label_1" and "delete Label_1".
    private(set) var labelCalls: [String] = []
    private var labelCallErrors: [String: (error: GmailError, afterApplying: Bool)] = [:]
    private var nextLabelID = 1

    /// The next label call of `kind` ("create", "patch", "delete") fails with
    /// `error`. With `afterApplying`, Gmail applies it first.
    func failNextLabelCall(_ kind: String, with error: GmailError, afterApplying: Bool = false) {
        labelCallErrors[kind] = (error, afterApplying)
    }

    private func labelCall(_ kind: String, _ call: String, apply: () throws -> Void) async throws {
        if holdsNextChange {
            holdsNextChange = false
            await withCheckedContinuation { held = $0 }
        }
        labelCalls.append(call)
        if let failure = labelCallErrors.removeValue(forKey: kind) {
            if failure.afterApplying { try apply() }
            throw failure.error
        }
        try apply()
    }

    /// Refuses a name already in use with 409, as Gmail does.
    func createLabel(name: String, color: LabelColor?) async throws -> GmailLabel {
        var created: GmailLabel?
        try await labelCall("create", "create \(name)") {
            guard !labelValues.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
                throw GmailError.http(status: 409, reason: nil)
            }
            let label = try userLabel(id: "Label_\(nextLabelID)", name: name, color: color)
            nextLabelID += 1
            labelValues.append(label)
            created = label
        }
        guard let created else { throw GmailError.notFound }
        return created
    }

    func patchLabel(id: String, name: String?, color: LabelColorChange?) async throws -> GmailLabel {
        var patched: GmailLabel?
        try await labelCall("patch", "patch \(id)") {
            guard let index = labelValues.firstIndex(where: { $0.id == id }) else { throw GmailError.notFound }
            let old = labelValues[index]
            let oldColor = old.color.flatMap { color in
                color.backgroundColor.flatMap { background in color.textColor.flatMap { LabelColor(backgroundColor: background, textColor: $0) } }
            }
            let newColor: LabelColor? = switch color {
            case nil: oldColor
            case .remove?: nil
            case .set(let value)?: value
            }
            labelValues[index] = try userLabel(id: id, name: name ?? old.name, color: newColor)
            patched = labelValues[index]
        }
        guard let patched else { throw GmailError.notFound }
        return patched
    }

    /// A label that's already gone counts as deleted, as in `GmailClient`.
    func deleteLabel(id: String) async throws {
        try await labelCall("delete", "delete \(id)") {
            labelValues.removeAll { $0.id == id }
        }
    }

    // MARK: Drafts

    /// Draft calls in order, such as "create", "update D1", "send D1" and "delete D1".
    private(set) var draftCalls: [String] = []
    private(set) var uploads: [OutgoingMessage] = []
    /// Gmail's drafts, by ID, with the message each holds.
    private(set) var draftsByID: [String: (messageID: String, threadID: String)] = [:]
    private var nextID = 1
    private var draftErrors: [String: GmailError] = [:]
    private var draftListings: [String: [String]] = [:]

    /// The next call of `kind` ("create", "update", "send", "delete") fails
    /// with `error`. With `afterApplying`, Gmail applies it first, as when a
    /// response is lost.
    func failNextDraftCall(_ kind: String, with error: GmailError, afterApplying: Bool = false) {
        draftErrors[kind] = error
        draftErrorsAfterApplying = afterApplying
    }
    private var draftErrorsAfterApplying = false

    func addDraft(_ id: String, messageID: String, threadID: String) { draftsByID[id] = (messageID, threadID) }
    func deleteDraftElsewhere(_ id: String) { draftsByID[id] = nil }
    /// `drafts.get` answers with this JSON for `id` instead of a bare message.
    func setDraftJSON(_ id: String, _ json: String) { draftJSONByID[id] = json }
    private var draftJSONByID: [String: String] = [:]
    func setDraftSearch(_ query: String, ids: [String]) { draftListings[query] = ids }

    private func draftCall(_ kind: String, _ call: String, apply: () -> Void) async throws {
        if holdsNextChange {
            holdsNextChange = false
            await withCheckedContinuation { held = $0 }
        }
        draftCalls.append(call)
        if let error = draftErrors.removeValue(forKey: kind) {
            if draftErrorsAfterApplying { apply() }
            throw error
        }
        apply()
    }

    private func storeDraftMessage(_ upload: OutgoingMessage, labels: [String]) -> GmailMessage? {
        let id = "msg\(nextID)"
        let thread = upload.threadID ?? "thread\(nextID)"
        nextID += 1
        let message = try? gmailMessage(id, thread: thread, labels: labels, historyID: 300 + nextID, minutes: 10)
        messagesByID[id] = message
        return message
    }

    func drafts(query: String?, pageToken: String?, maxResults: Int) throws -> DraftListPage {
        let ids = query.flatMap { draftListings[$0] } ?? draftsByID.keys.sorted()
        let entries = ids.compactMap { id in draftsByID[id].map { #"{"id":"\#(id)","message":{"id":"\#($0.messageID)","threadId":"\#($0.threadID)"}}"# } }
        return try decode(DraftListPage.self, #"{"drafts":[\#(entries.joined(separator: ","))]}"#)
    }

    func draft(id: String, format: MessageFormat) throws -> GmailDraft {
        if let json = draftJSONByID[id] { return try decode(GmailDraft.self, json) }
        guard let stored = draftsByID[id], let message = messagesByID[stored.messageID] else { throw GmailError.notFound }
        return try decode(GmailDraft.self, #"{"id":"\#(id)","message":\#(try encodedMessage(message.id, thread: message.threadId, labels: message.labelIds ?? []))}"#)
    }

    func createDraft(_ message: OutgoingMessage) async throws -> GmailDraft {
        let id = "D\(nextID)"
        var stored: GmailMessage?
        try await draftCall("create", "create") {
            uploads.append(message)
            stored = storeDraftMessage(message, labels: [SystemLabel.draft])
            if let stored { draftsByID[id] = (stored.id, stored.threadId) }
        }
        return try decode(GmailDraft.self, #"{"id":"\#(id)","message":{"id":"\#(stored?.id ?? "")","threadId":"\#(stored?.threadId ?? "")"}}"#)
    }

    func updateDraft(id: String, with message: OutgoingMessage) async throws -> GmailDraft {
        var stored: GmailMessage?
        try await draftCall("update", "update \(id)") {
            guard let old = draftsByID[id] else { return }
            uploads.append(message)
            messagesByID[old.messageID] = nil
            stored = storeDraftMessage(OutgoingMessage(raw: message.raw, threadID: old.threadID), labels: [SystemLabel.draft])
            if let stored { draftsByID[id] = (stored.id, stored.threadId) }
        }
        guard let stored else { throw GmailError.notFound }
        return try decode(GmailDraft.self, #"{"id":"\#(id)","message":{"id":"\#(stored.id)","threadId":"\#(stored.threadId)"}}"#)
    }

    func sendDraft(id: String, with message: OutgoingMessage) async throws -> GmailMessage {
        var sent: GmailMessage?
        try await draftCall("send", "send \(id)") {
            guard let old = draftsByID.removeValue(forKey: id) else { return }
            uploads.append(message)
            messagesByID[old.messageID] = nil
            sent = storeDraftMessage(OutgoingMessage(raw: message.raw, threadID: old.threadID), labels: [SystemLabel.sent])
        }
        guard let sent else { throw GmailError.notFound }
        return sent
    }

    func deleteDraft(id: String) async throws {
        var found = false
        try await draftCall("delete", "delete \(id)") {
            guard let old = draftsByID.removeValue(forKey: id) else { return }
            messagesByID[old.messageID] = nil
            found = true
        }
        if !found { throw GmailError.notFound }
    }
}

struct TestClock: Sendable {
    private let date = OSAllocatedUnfairLock(initialState: baseDate)

    var now: @Sendable () -> Date { { [date] in date.withLock { $0 } } }

    func advance(_ seconds: TimeInterval) {
        date.withLock { $0 += seconds }
    }
}

private func makeEngine() async throws -> (SyncEngine, MailCache, FakeGmail, TestClock) {
    let cache = try MailCache.inMemory()
    let gmail = FakeGmail()
    let clock = TestClock()
    let engine = SyncEngine(
        accountID: account,
        sender: EmailAddress(name: "Me", address: "me@example.com"),
        outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: "TernTests-\(UUID().uuidString)", directoryHint: .isDirectory),
        gmail: gmail,
        cache: cache,
        sendsAutomatically: false,
        now: clock.now
    )
    return (engine, cache, gmail, clock)
}

/// Stores messages a minute apart, oldest first.
private func seed(_ cache: MailCache, _ messages: [(id: String, thread: String, labels: [String])], cursor: Int64? = nil) async throws {
    let updates = messages.enumerated().map { index, message in
        CacheTransaction.MessageUpdate(
            record: MessageRecord(
                accountID: account, id: message.id, threadID: message.thread, historyID: 1,
                date: baseDate.addingTimeInterval(Double(index) * 60), snippet: "", sender: "A <a@example.com>",
                recipients: "", cc: nil, subject: "Subject", sizeEstimate: 0
            ),
            labelIDs: message.labels
        )
    }
    try await cache.write { tx in
        try tx.rebuildThreads(try tx.upsertMessages(updates), accountID: account)
        if let cursor { try tx.saveCursor(historyID: cursor, accountID: account) }
    }
}

private func gmailMessage(_ id: String, thread: String, labels: [String], historyID: Int, minutes: Double = 0) throws -> GmailMessage {
    try decode(GmailMessage.self, try encodedMessage(id, thread: thread, labels: labels, historyID: historyID, minutes: minutes))
}

private func encodedMessage(
    _ id: String, thread: String, labels: [String] = [SystemLabel.inbox], historyID: Int = 100, minutes: Double = 0
) throws -> String {
    let milliseconds = Int(baseDate.addingTimeInterval(minutes * 60).timeIntervalSince1970 * 1000)
    let labelJSON = String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)
    return """
        {"id": "\(id)", "threadId": "\(thread)", "labelIds": \(labelJSON), "historyId": "\(historyID)",
         "internalDate": "\(milliseconds)", "snippet": "Hi &amp; bye",
         "payload": {"headers": [{"name": "From", "value": "B <b@example.com>"}, {"name": "Subject", "value": "New"}]}}
        """
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func userLabel(id: String, name: String, color: LabelColor?) throws -> GmailLabel {
    var json: [String: Any] = ["id": id, "name": name, "type": "user"]
    if let color { json["color"] = ["backgroundColor": color.backgroundColor, "textColor": color.textColor] }
    return try JSONDecoder().decode(GmailLabel.self, from: JSONSerialization.data(withJSONObject: json))
}

private func threadIDs(_ cache: MailCache, _ labelID: String) async throws -> [String] {
    for try await threads in cache.threads(accountID: account, labelID: labelID, limit: 100) {
        return threads.map(\.id)
    }
    return []
}

private func pendingActions(_ cache: MailCache) async throws -> [PendingAction] {
    try await cache.read { tx in try tx.pendingActions(accountID: account) }
}
