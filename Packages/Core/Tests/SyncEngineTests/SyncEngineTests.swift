import Foundation
import GmailAPI
import MailStore
import os
import Testing
@testable import SyncEngine

private let account = "acct"
private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct ActionQueueTests {
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
}

@Suite struct SyncPassTests {
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

    @Test func expiredCursorResyncsAndKeepsMessagesPendingActionsTarget() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        try await seed(cache, [
            ("m1", "t1", [SystemLabel.inbox]),
            ("m8", "t8", [SystemLabel.inbox]),
            ("m9", "t9", [SystemLabel.inbox]),
        ], cursor: 100)
        try await engine.perform(.archive, threadIDs: ["t8"])

        await gmail.expireHistory()
        await gmail.add(try gmailMessage("m1", thread: "t1", labels: [SystemLabel.inbox], historyID: 150), inInbox: true)
        try await engine.sync()

        #expect(try await cache.syncState(accountID: account)?.historyID == 200)
        #expect(try await cache.read { tx in try tx.cachedMessageIDs(accountID: account) } == ["m1", "m8"])
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
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
    private var historyExpired = false
    private let profileHistoryID = "200"

    func add(_ message: GmailMessage, inInbox: Bool = false) {
        messagesByID[message.id] = message
        if inInbox { inboxIDs.append(message.id) }
    }

    func queueHistory(_ page: HistoryPage) { historyPages.append(page) }
    func expireHistory() { historyExpired = true }

    func profile() async throws -> GmailProfile {
        try decode(GmailProfile.self, #"{"emailAddress": "me@example.com", "historyId": "\#(profileHistoryID)"}"#)
    }

    func labels() async throws -> [GmailLabel] { [] }
    func labels(ids: [String]) async throws -> [String: Result<GmailLabel, GmailError>] { [:] }

    func listMessages(
        query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int
    ) async throws -> MessageListPage {
        let ids = labelIDs.contains(SystemLabel.inbox) ? inboxIDs : []
        let refs = ids.compactMap { messagesByID[$0] }.map { #"{"id": "\#($0.id)", "threadId": "\#($0.threadId)"}"# }
        return try decode(MessageListPage.self, #"{"messages": [\#(refs.joined(separator: ","))]}"#)
    }

    func messages(ids: [String], format: MessageFormat, metadataHeaders: [String]) async throws -> [String: Result<GmailMessage, GmailError>] {
        Dictionary(uniqueKeysWithValues: ids.map { id in (id, messagesByID[id].map { .success($0) } ?? .failure(.notFound)) })
    }

    func thread(id: String, format: MessageFormat) async throws -> GmailThread {
        throw GmailError.notFound
    }

    func history(startHistoryID: String, pageToken: String?) async throws -> HistoryPage {
        if historyExpired { throw GmailError.notFound }
        guard !historyPages.isEmpty else { return try decode(HistoryPage.self, #"{"historyId": "\#(startHistoryID)"}"#) }
        return historyPages.removeFirst()
    }

    func modifyThreads(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws -> [String: GmailError] {
        changes.append(Change("modifyThreads", ids, add: addLabelIDs, remove: removeLabelIDs))
        return [:]
    }

    func trashThreads(ids: [String]) async throws -> [String: GmailError] {
        changes.append(Change("trash", ids))
        return [:]
    }

    func untrashThreads(ids: [String]) async throws -> [String: GmailError] {
        changes.append(Change("untrash", ids))
        return [:]
    }

    func batchModifyMessages(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) async throws {
        changes.append(Change("batchModify", ids, add: addLabelIDs, remove: removeLabelIDs))
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
    let milliseconds = Int(baseDate.addingTimeInterval(minutes * 60).timeIntervalSince1970 * 1000)
    let labelJSON = String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)
    return try decode(GmailMessage.self, """
        {"id": "\(id)", "threadId": "\(thread)", "labelIds": \(labelJSON), "historyId": "\(historyID)",
         "internalDate": "\(milliseconds)", "snippet": "Hi &amp; bye",
         "payload": {"headers": [{"name": "From", "value": "B <b@example.com>"}, {"name": "Subject", "value": "New"}]}}
        """)
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
