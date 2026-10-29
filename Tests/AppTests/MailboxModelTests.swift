import AppKit
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct MailboxModelTests {
    @Test func commandsUseTheOpenMailboxWithoutAFirstResponder() async throws {
        // The test host's scheme uses --ui-audit, so no real account is opened.
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let commands = MailCommands(app: app)
        #expect(commands.mailbox === mailbox)
        await app.signOut()
        #expect(commands.mailbox == nil)
        #expect(app.phase == .signedOut)
    }

    @Test func archiveKeepsSelectionOutsideInboxAndObservationsRemoveStaleSelection() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && !mailbox.threads.isEmpty }
        mailbox.selectedLabelID = SystemLabel.allMail
        try await waitUntil { mailbox.threads.count == 4 }
        mailbox.selectedThreadIDs = ["t1"]
        await mailbox.perform(.archive)?.value
        #expect(mailbox.selectedThreadIDs == ["t1"])
        mailbox.selectedLabelID = SystemLabel.trash
        #expect(mailbox.threads.isEmpty)
        #expect(mailbox.selectedThreadIDs.isEmpty)
        try await waitUntil { mailbox.threads.map(\.id) == ["t4"] }
        mailbox.selectedThreadIDs = ["t4"]
        try await cache.write { tx in
            try tx.rebuildThreads(try tx.deleteMessages(ids: ["m5"], accountID: account.id), accountID: account.id)
        }
        try await waitUntil { mailbox.threads.isEmpty }
        #expect(mailbox.selectedThreadIDs.isEmpty)
        await mailbox.stop()
    }

    @Test func searchListsLocalMatchesAndGmailsThenEscapeReturnsToTheMailbox() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && mailbox.threads.count == 2 }
        mailbox.selectedThreadIDs = ["t1"]

        // Local matches come from every mailbox, and the selection stays inside the list.
        mailbox.search.update("plans")
        try await waitUntil { mailbox.listedThreads.map(\.id).sorted() == ["t2", "t3"] }
        #expect(mailbox.selectedThreadIDs.isEmpty)

        // Gmail alone answers this query, so its conversations make up the list.
        mailbox.search.update("has:attachment")
        try await waitUntil { mailbox.listedThreads.isEmpty }
        mailbox.search.submit()
        try await waitUntil { mailbox.search.gmail?.state == .finished }
        try await waitUntil { mailbox.listedThreads.map(\.id).sorted() == ["t1", "t2", "t3", "t5"] }

        mailbox.search.cancel()
        #expect(!mailbox.search.isActive)
        #expect(mailbox.listedThreads.map(\.id).sorted() == ["t1", "t2"])
        await mailbox.stop()
    }

    @Test func editLabelsStartsFromTheConversationsLabelsAndMoveLeavesTheMailbox() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && mailbox.threads.count == 2 && !mailbox.labelChoices.isEmpty }

        mailbox.showEditLabels(for: ["t2"])
        try await waitUntil { mailbox.labelEdit != nil }
        #expect(mailbox.labelEdit?.applied.first?.contains("Label_1") == false)
        await mailbox.applyLabels(LabelSelection.Change(add: ["Label_1"]))?.value
        #expect(mailbox.labelEdit == nil)
        mailbox.showEditLabels(for: ["t2"])
        try await waitUntil { mailbox.labelEdit?.applied.first?.contains("Label_1") == true }
        mailbox.labelEdit = nil

        // Moving out of the Inbox selects the next conversation.
        mailbox.selectedThreadIDs = ["t1"]
        mailbox.showMoveTo()
        #expect(!mailbox.moveChoices.contains { $0.id == SystemLabel.inbox })
        let move = mailbox.move(to: "Label_1")
        #expect(mailbox.selectedThreadIDs == ["t2"])
        await move?.value
        try await waitUntil { mailbox.threads.map(\.id) == ["t2"] }
        #expect(mailbox.notice?.message == "Conversation moved to “Hiking”")
        await mailbox.stop()
    }

    @Test func snoozeMovesTheConversationToSnoozedAndUndoEndsTheSnooze() async throws {
        let cache = try MailCache.inMemory()
        let accounts = try AccountStore.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        try await accounts.save(account)
        let mailbox = MailboxModel(
            account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory, snoozeStore: accounts
        )
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && mailbox.threads.count == 2 }
        mailbox.selectedThreadIDs = ["t1"]
        #expect(mailbox.canSnooze)

        // A preset worked out before its time passed is refused.
        #expect(mailbox.snooze(until: .now.addingTimeInterval(-60)) == nil)
        #expect(mailbox.notice?.isError == true)

        let snooze = mailbox.snooze(until: .now.addingTimeInterval(3600))
        #expect(mailbox.selectedThreadIDs == ["t2"])
        await snooze?.value
        try await waitUntil { mailbox.threads.map(\.id) == ["t2"] && mailbox.snoozed.map(\.id) == ["t1"] }
        #expect(try await accounts.snoozes(accountID: account.id).map(\.threadID) == ["t1"])
        mailbox.selectedLabelID = MailboxModel.snoozedID
        #expect(mailbox.threads.map(\.id) == ["t1"])
        #expect(mailbox.wakeTimes["t1"] != nil)

        // Undo from the notice takes back the archive, the hold and the record.
        guard case .action(let receipt)? = mailbox.notice?.undo else {
            Issue.record("Snooze left no notice with Undo")
            return
        }
        mailbox.undo(receipt)
        try await waitUntil { mailbox.snoozed.isEmpty && mailbox.threads.isEmpty }
        #expect(try await accounts.snoozes(accountID: account.id).isEmpty)
        mailbox.selectedLabelID = SystemLabel.inbox
        try await waitUntil { mailbox.threads.map(\.id).sorted() == ["t1", "t2"] }
        await mailbox.stop()
    }

    @Test func undoIsAvailableBeforePersistenceAndCommandsHaveSeparateGroups() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        let manager = UndoManager()
        manager.groupsByEvent = false
        mailbox.undoManager = manager
        let first = try #require(mailbox.perform(.archive, on: ["t1"]))
        // Registration belongs to the initiating event, before any await.
        #expect(manager.canUndo)
        #expect(manager.undoActionName == "Archive")
        let second = try #require(mailbox.perform(.markUnread, on: ["t2"]))
        #expect(manager.undoActionName == "Mark as Unread")
        manager.undo()
        #expect(manager.undoActionName == "Archive")
        manager.undo()
        #expect(!manager.canUndo)
        await first.value
        await second.value
        #expect(try await cache.read { tx in try tx.pendingActions(accountID: account.id) }.isEmpty)
        #expect(mailbox.retainedUndoCount == 0)
        await mailbox.stop()
    }

    @Test func undoTargetsAreBoundedAndReleasedWhenTheMailboxStops() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        let manager = UndoManager()
        manager.groupsByEvent = false
        mailbox.undoManager = manager
        for _ in 0..<(MailboxModel.undoLimit + 5) { mailbox.perform(.archive, on: ["t1"]) }
        #expect(mailbox.retainedUndoCount == MailboxModel.undoLimit)
        #expect(manager.levelsOfUndo == MailboxModel.undoLimit)
        await mailbox.stop()
        #expect(mailbox.retainedUndoCount == 0)
        #expect(!manager.canUndo)
    }

    @Test func outboxStaysSelectedWhileLabelsLoadAndListsWaitingSends() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let outgoing = FileManager.default.temporaryDirectory.appending(path: "TernOutboxTests-\(UUID().uuidString)")
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: outgoing)
        mailbox.selectedLabelID = MailboxModel.outboxID
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && !mailbox.userLabels.isEmpty }
        #expect(mailbox.selectedLabelID == MailboxModel.outboxID)
        #expect(mailbox.threads.isEmpty)

        let id = try #require(await mailbox.startCompose(.newMessage))
        try await mailbox.engine.sendDraft(id, delay: 60)
        try await waitUntil { mailbox.outbox.map(\.id) == [id] }
        #expect(await mailbox.undoSend(id))
        try await waitUntil { mailbox.outbox.isEmpty }
        #expect(mailbox.showsOutbox)
        mailbox.selectedLabelID = SystemLabel.inbox
        #expect(!mailbox.showsOutbox)
        await mailbox.stop()
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition(), "Mailbox observation did not reach the expected state")
}
