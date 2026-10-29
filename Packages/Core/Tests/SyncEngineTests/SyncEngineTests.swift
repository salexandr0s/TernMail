import Foundation
import GmailAPI
import MailStore
import os
import Testing
@testable import SyncEngine

private let account = "acct"
private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct ActionQueueTests {
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
        await sending.value

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
              {"mimeType":"text/plain","filename":"notes.txt","body":{"attachmentId":"file"}}
            ]}}]}
            """#))
        await gmail.setAttachment("body", data: try #require("Café".data(using: .isoLatin1)))
        try await engine.openThread("t1")
        for try await detail in cache.thread(accountID: account, threadID: "t1") {
            #expect(detail?.messages.first?.body?.plainText == "Café")
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
        guard let thread = threadsByID[id] else { throw GmailError.notFound }
        if holdsThread {
            holdsThread = false
            await withCheckedContinuation { heldThread = $0 }
        }
        return thread
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
    let engine = SyncEngine(accountID: account, gmail: gmail, cache: cache, sendsAutomatically: false, now: clock.now)
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

private func threadIDs(_ cache: MailCache, _ labelID: String) async throws -> [String] {
    for try await threads in cache.threads(accountID: account, labelID: labelID, limit: 100) {
        return threads.map(\.id)
    }
    return []
}

private func pendingActions(_ cache: MailCache) async throws -> [PendingAction] {
    try await cache.read { tx in try tx.pendingActions(accountID: account) }
}
