import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct TriageQueueTests {
    @Test func aMessageActionLeavesItsConversationSiblingAloneAndUndoIsExact() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t1", [SystemLabel.inbox])])
        let receipt = try #require(try await engine.perform(.archive, target: .messages(["m1"])))
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        clock.advance(3)
        _ = await engine.sendDueActions()
        #expect(await gmail.changes == [Change("batchModify", ["m1"], remove: [SystemLabel.inbox])])
        try await engine.undo(receipt)
        _ = await engine.sendDueActions()
        #expect(await gmail.changes.last == Change("batchModify", ["m1"], add: [SystemLabel.inbox]))
        await engine.stop()
    }

    @Test func markAllReadAndUndoUseTheCapturedUnreadMessagesOnly() async throws {
        let (engine, _, gmail, clock) = try await makeEngine()
        await gmail.add(try gmailMessage("m1", thread: "t1", labels: [SystemLabel.inbox, SystemLabel.unread]))
        await gmail.add(try gmailMessage("m2", thread: "t2", labels: [SystemLabel.inbox]))
        await gmail.setRecentPages([try decode(MessageListPage.self, #"{"messages":[{"id":"m1","threadId":"t1"},{"id":"m2","threadId":"t2"}]}"#)])
        let receipt = try #require(try await engine.markAllRead(labelID: SystemLabel.inbox))
        await gmail.add(try gmailMessage("later", thread: "t3", labels: [SystemLabel.inbox, SystemLabel.unread]))
        clock.advance(3)
        _ = await engine.sendDueActions()
        try await engine.undo(receipt)
        _ = await engine.sendDueActions()
        #expect(await gmail.changes == [
            Change("batchModify", ["m1"], remove: [SystemLabel.unread]),
            Change("batchModify", ["m1"], add: [SystemLabel.unread]),
        ])
        await engine.stop()
    }

    @Test func permanentDeletionUsesApprovedIDsSkipsRescuedMailAndRequiresCurrentPermission() async throws {
        let (engine, cache, gmail, triage, accounts, _) = try await makeTriageEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.trash]), ("m2", "t2", [SystemLabel.trash])])
        await gmail.add(try gmailMessage("m1", thread: "t1", labels: [SystemLabel.trash]))
        await gmail.add(try gmailMessage("m2", thread: "t2", labels: [SystemLabel.trash]))
        let review = try await engine.preparePermanentDeletion(labelID: SystemLabel.trash, target: .messages(["m1", "m2"]))
        #expect(review.count == 2)
        await gmail.add(try gmailMessage("m2", thread: "t2", labels: [SystemLabel.inbox]))
        await gmail.add(try gmailMessage("later", thread: "t3", labels: [SystemLabel.trash]))
        try await engine.deletePermanently(approved: review)
        _ = await engine.sendDueActions()
        #expect(await triage.deleted == [["m1"]])
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: account) } == ["m2"])

        let next = try await engine.preparePermanentDeletion(labelID: SystemLabel.trash, target: .messages(["later"]))
        _ = try await accounts.updateAccount(id: account) { $0.enabledFeatures = [] }
        await #expect(throws: GmailError.http(status: 403, reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT")) {
            try await engine.deletePermanently(approved: next)
        }
        #expect(await triage.deleted == [["m1"]])
        await #expect(throws: TriageError.invalidDeletionScope) {
            try await engine.preparePermanentDeletion(labelID: SystemLabel.inbox)
        }
        await engine.stop()
    }

    @Test func retainedFailureDoesNotProjectOrBlockAndRetryReusesItsRow() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox])])
        _ = try await engine.perform(.archive, threadIDs: ["t1"])
        await gmail.failNextChange(with: .http(status: 403, reason: "forbidden"))
        clock.advance(3)
        _ = await engine.sendDueActions()
        let failed = try #require(try await cache.read { try $0.failedActions(accountID: account).first })
        let id = try #require(failed.id)
        #expect(failed.lastError?.contains("forbidden") == true)
        #expect(try await pendingActions(cache).isEmpty)
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        _ = try await engine.perform(.markUnread, target: .messages(["m1"]))
        clock.advance(3)
        #expect(await engine.sendDueActions() == 1)
        #expect(try await engine.retryFailedAction(id: id))
        #expect(try await engine.retryFailedAction(id: id) == false)
        #expect(try await cache.read { try $0.allActions(accountID: account).count } == 2)
        #expect(await engine.sendDueActions() == 1)
        #expect(try await cache.read { try $0.action(id: id)?.state } == .sent)
        await engine.stop()
    }

    @Test func visibilityIsProjectedAndUndoRestoresThePreviousChoice() async throws {
        let (engine, cache, _, triage, _, clock) = try await makeTriageEngine()
        try await cache.write { tx in
            try tx.replaceLabels([LabelRecord(accountID: account, id: "Label_work", name: "Work", isSystem: false)], accountID: account)
        }
        let receipt = try #require(try await engine.setLabelVisibility("Label_work", to: .hide))
        #expect(try await cache.read { try $0.displayedLabels(accountID: account).first?.labelListVisibility } == "labelHide")
        clock.advance(3)
        _ = await engine.sendDueActions()
        try await engine.undo(receipt)
        _ = await engine.sendDueActions()
        #expect(await triage.visibility == [.hide, .show])
        await engine.stop()
    }

    @Test func aFailedSendKeepsItsIntentAndRetryReopensTheSameQueueRow() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        let draft = makeDraft()
        try await engine.createDraft(draft)
        try await engine.saveDraft(draft.id)
        _ = await engine.sendDueDrafts()
        await gmail.failNextDraftCall("send", with: .http(status: 400, reason: "invalidArgument"))
        _ = try await engine.sendDraft(draft.id, delay: 0)
        _ = await engine.sendDueDrafts()
        let failed = try #require(try await cache.read { try $0.failedActions(accountID: account).first })
        let id = try #require(failed.id)
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.state } == .editing)
        #expect(try await cache.read { try $0.thread(id: "thread1", accountID: account) } != nil)
        #expect(try await engine.retryFailedAction(id: id))
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.state } == .sending)
        #expect(try await cache.read { try $0.thread(id: "thread1", accountID: account) } == nil)
        _ = await engine.sendDueDrafts()
        #expect(try await cache.read { try $0.localDraft(id: draft.id) } == nil)
        #expect(try await cache.read { try $0.allActions(accountID: account).isEmpty })
        await engine.stop()
    }

    @Test func undoMessageTrashRestoresInboxAndKeepsTheAlreadyTrashedSibling() async throws {
        let (engine, cache, gmail, triage, _, clock) = try await makeTriageEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.inbox]), ("m2", "t1", [SystemLabel.trash])])
        await gmail.add(try gmailMessage("m1", thread: "t1", labels: [SystemLabel.inbox]))
        await gmail.add(try gmailMessage("m2", thread: "t1", labels: [SystemLabel.trash]))
        let receipt = try #require(try await engine.perform(.trash, target: .messages(["m1", "m2"])))
        clock.advance(3)
        _ = await engine.sendDueActions()
        try await engine.undo(receipt)
        while await engine.sendDueActions() > 0 {}
        #expect(await triage.trashed == [["m1", "m2"]])
        #expect(await triage.untrashed == [["m1"]])
        #expect(await gmail.changes == [Change("batchModify", ["m1"], add: [SystemLabel.inbox])])
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        #expect(try await threadIDs(cache, SystemLabel.trash) == ["t1"])
        await engine.stop()
    }

    @Test func uncachedMessageTargetsKeepTheirOrderAcrossBackoff() async throws {
        let (engine, _, gmail, clock) = try await makeEngine()
        _ = try await engine.perform(.markRead, target: .messages(["remote"]))
        await gmail.failNextChange(with: .rateLimited)
        clock.advance(3)
        #expect(await engine.sendDueActions() == 1)
        _ = try await engine.perform(.star, target: .messages(["remote"]))
        clock.advance(2)
        #expect(await engine.sendDueActions() == 1)
        #expect(await gmail.changes.count == 2)
        #expect(await engine.sendDueActions() == 1)
        #expect(await gmail.changes.last == Change("batchModify", ["remote"], add: [SystemLabel.starred]))
        await engine.stop()
    }

    @Test func aMessageMovedFromTrashToTheInboxLeavesTrash() async throws {
        let (engine, cache, gmail, clock) = try await makeEngine()
        try await seed(cache, [("m1", "t1", [SystemLabel.trash])])
        _ = try #require(try await engine.move(target: .messages(["m1"]), to: SystemLabel.inbox, from: SystemLabel.trash))
        #expect(try await threadIDs(cache, SystemLabel.inbox) == ["t1"])
        #expect(try await threadIDs(cache, SystemLabel.trash).isEmpty)
        clock.advance(3)
        _ = await engine.sendDueActions()
        #expect(await gmail.changes == [Change("batchModify", ["m1"], add: [SystemLabel.inbox], remove: [SystemLabel.trash])])
        await engine.stop()
    }
}

private actor FakeTriageService: TriageService {
    private(set) var deleted: [[String]] = []
    private(set) var visibility: [LabelListVisibility] = []
    private(set) var trashed: [[String]] = []
    private(set) var untrashed: [[String]] = []
    func rawMessage(id: String) -> Data { Data() }
    func batchDeleteMessages(ids: [String]) { if !ids.isEmpty { deleted.append(ids) } }
    func trashMessages(ids: [String]) -> [String: GmailError] { trashed.append(ids); return [:] }
    func untrashMessages(ids: [String]) -> [String: GmailError] { untrashed.append(ids); return [:] }
    func patchLabelVisibility(id: String, visibility: LabelListVisibility) throws -> GmailLabel {
        self.visibility.append(visibility)
        return try decode(GmailLabel.self, #"{"id":"\#(id)","name":"Work","labelListVisibility":"\#(visibility.rawValue)"}"#)
    }
}

private func makeTriageEngine() async throws -> (SyncEngine, MailCache, FakeGmail, FakeTriageService, AccountStore, TestClock) {
    let cache = try MailCache.inMemory()
    let gmail = FakeGmail()
    let triage = FakeTriageService()
    let accounts = try AccountStore.inMemory()
    try await accounts.save(AccountRecord(id: account, email: "me@example.com", displayName: "Me",
        grantedScopes: GoogleScopes.base + [GoogleScopes.fullMail], addedAt: baseDate,
        enabledFeatures: [AccountFeature.permanentDeletion.rawValue]))
    let clock = TestClock()
    let engine = SyncEngine(accountID: account, sender: EmailAddress(address: "me@example.com"),
        outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
        gmail: gmail, triage: triage, accounts: accounts, cache: cache, sendsAutomatically: false, now: clock.now)
    return (engine, cache, gmail, triage, accounts, clock)
}

private func gmailMessage(_ id: String, thread: String, labels: [String]) throws -> GmailMessage {
    try decode(GmailMessage.self, try encodedMessage(id, thread: thread, labels: labels))
}

private func threadIDs(_ cache: MailCache, _ labelID: String) async throws -> [String] {
    for try await threads in cache.threads(accountID: account, labelID: labelID, limit: 100) { return threads.map(\.id) }
    return []
}

private func pendingActions(_ cache: MailCache) async throws -> [PendingAction] {
    try await cache.read { try $0.pendingActions(accountID: account) }
}

private func makeDraft() -> LocalDraft {
    LocalDraft(accountID: account, kind: .new,
        content: DraftContent(to: [EmailAddress(address: "ana@example.com")], subject: "Plan", body: ComposeDocument(plainText: "Ready")),
        rfcMessageID: "<triage-draft@example.com>", now: baseDate)
}
