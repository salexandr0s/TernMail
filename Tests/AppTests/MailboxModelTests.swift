import AppKit
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct MailboxModelTests {
    @Test func failedMessageLoadCanRetryAndCancellationStaysQuiet() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let gmail = AuditGmail()
        let mailbox = MailboxModel(account: account, cache: cache, gmail: gmail, outgoingDirectory: FileManager.default.temporaryDirectory)
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && mailbox.threads.count == 2 }
        let key = ThreadKey(accountID: account.id, threadID: "t1")

        await gmail.failNextThreadLoad()
        #expect(await mailbox.open(key) == false)
        #expect(mailbox.notice?.isError == true)
        #expect(try await cache.read { tx in try tx.body(messageID: "m1", accountID: account.id) } == nil)

        #expect(await mailbox.open(key))
        #expect(try await cache.read { tx in try tx.body(messageID: "m1", accountID: account.id) }?.html != nil)

        mailbox.notice = nil
        let cancelled = Task { await mailbox.open(key) }
        cancelled.cancel()
        #expect(await cancelled.value == false)
        #expect(mailbox.notice == nil)
        await mailbox.stop()
    }

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

    @Test func signingOutOfOneAccountKeepsTheOtherAndDeletesOnlyItsMail() async throws {
        // Audit mode opens two accounts.
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        try await waitUntil { mailbox.hasSeveralAccounts && mailbox.hasSyncedOnce }
        let cache = try #require(app.cache)
        #expect(try await cache.read { tx in try tx.cachedAccountIDs() } == ["ui-audit", "ui-audit-2"])

        await app.signOut(of: "ui-audit")
        #expect(app.mailbox === mailbox)
        #expect(app.phase == .signedIn(mailbox.account))
        #expect(mailbox.account.id == "ui-audit-2")
        #expect(mailbox.selectedMailbox == .account("ui-audit-2", SystemLabel.inbox))
        #expect(try await cache.read { tx in try tx.cachedAccountIDs() } == ["ui-audit-2"])
        try await waitUntil { mailbox.threads.count == 2 }
        #expect(mailbox.threads.allSatisfy { $0.accountID == "ui-audit-2" })
        await app.signOut()
    }

    @Test func archiveKeepsSelectionOutsideInboxAndObservationsRemoveStaleSelection() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && !mailbox.threads.isEmpty }
        mailbox.selectedMailbox = .account("audit", SystemLabel.allMail)
        try await waitUntil { mailbox.threads.count == 4 }
        // The j and k keys start at the first conversation and stop at the ends.
        let listed = mailbox.threads.map(\.key)
        mailbox.selectAdjacentThread(-1)
        #expect(mailbox.selectedThreadIDs == [listed[0]])
        mailbox.selectAdjacentThread(1)
        #expect(mailbox.selectedThreadIDs == [listed[1]])
        mailbox.selectedThreadIDs = [listed[3]]
        mailbox.selectAdjacentThread(1)
        #expect(mailbox.selectedThreadIDs == [listed[3]])
        mailbox.selectedThreadIDs = keys("t1")
        await mailbox.perform(.archive)?.value
        #expect(mailbox.selectedThreadIDs == keys("t1"))
        mailbox.selectedMailbox = .account("audit", SystemLabel.trash)
        #expect(mailbox.threads.isEmpty)
        #expect(mailbox.selectedThreadIDs.isEmpty)
        try await waitUntil { mailbox.threads.map(\.id) == ["t4"] }
        mailbox.selectedThreadIDs = keys("t4")
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
        mailbox.selectedThreadIDs = keys("t1")

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

        mailbox.showEditLabels(for: keys("t2"))
        try await waitUntil { mailbox.labelEdit != nil }
        #expect(mailbox.labelEdit?.applied.first?.contains("Label_1") == false)
        await mailbox.applyLabels(LabelSelection.Change(add: ["Label_1"]))?.value
        #expect(mailbox.labelEdit == nil)
        mailbox.showEditLabels(for: keys("t2"))
        try await waitUntil { mailbox.labelEdit?.applied.first?.contains("Label_1") == true }

        // Create Label applies the boxes already changed, then opens New Label.
        await mailbox.createLabel(named: "Trips", after: LabelSelection.Change(remove: ["Label_1"]))?.value
        #expect(mailbox.labelEdit == nil)
        guard case .new(let applyingTo)? = mailbox.labelEditor?.kind else {
            Issue.record("Create Label didn't open New Label")
            return
        }
        #expect(applyingTo == keys("t2"))
        mailbox.labelEditor = nil
        mailbox.showEditLabels(for: keys("t2"))
        try await waitUntil { mailbox.labelEdit?.applied.first?.contains("Label_1") == false }
        mailbox.labelEdit = nil

        // Moving out of the Inbox selects the next conversation.
        mailbox.selectedThreadIDs = keys("t1")
        mailbox.showMoveTo()
        #expect(!mailbox.moveChoices.contains { $0.id == SystemLabel.inbox })
        let move = mailbox.move(to: "Label_1")
        #expect(mailbox.selectedThreadIDs == keys("t2"))
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
        mailbox.selectedThreadIDs = keys("t1")
        #expect(mailbox.canSnooze)

        // A preset worked out before its time passed is refused.
        #expect(mailbox.snooze(until: .now.addingTimeInterval(-60)) == nil)
        #expect(mailbox.notice?.isError == true)

        // The receipt keeps sub-millisecond precision while SQLite stores
        // milliseconds. Undo must still remove the archive queue row.
        let wakeAt = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970) + 3600.123456)
        let snooze = mailbox.snooze(until: wakeAt)
        #expect(mailbox.selectedThreadIDs == keys("t2"))
        await snooze?.value
        try await waitUntil { mailbox.threads.map(\.id) == ["t2"] && mailbox.snoozed.map(\.id) == ["t1"] }
        #expect(try await accounts.snoozes(accountID: account.id).map(\.threadID) == ["t1"])
        mailbox.selectedMailbox = .account("audit", MailboxModel.snoozedID)
        #expect(mailbox.threads.map(\.id) == ["t1"])
        #expect(mailbox.wakeTimes[key("t1")] != nil)

        // Undo from the notice takes back the archive, the hold and the record.
        guard case .action(let receipt)? = mailbox.notice?.undo else {
            Issue.record("Snooze left no notice with Undo")
            return
        }
        mailbox.undo(receipt)
        try await waitUntil { mailbox.snoozed.isEmpty && mailbox.threads.isEmpty }
        #expect(try await accounts.snoozes(accountID: account.id).isEmpty)
        mailbox.selectedMailbox = .account("audit", SystemLabel.inbox)
        try await waitUntil { mailbox.threads.map(\.id).sorted() == ["t1", "t2"] }
        await mailbox.stop()
    }

    @Test func aCombinedInboxKeepsSameIDsApartAndOneUndoRevertsAMixedArchive() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let second = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        // Both fake accounts hold the same thread IDs.
        await mailbox.addAccount(second, gmail: AuditGmail())
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        await mailbox.start()
        let otherT1 = ThreadKey(accountID: "second", threadID: "t1")
        let otherT2 = ThreadKey(accountID: "second", threadID: "t2")
        try await waitUntil { mailbox.hasSyncedOnce && mailbox.threads.count == 4 }
        #expect(Set(mailbox.threads.map(\.key)) == keys("t1", "t2").union([otherT1, otherT2]))

        // One archive across both accounts, then one Undo for both.
        mailbox.selectedThreadIDs = [key("t1"), otherT1]
        await mailbox.perform(.archive)?.value
        try await waitUntil { Set(mailbox.threads.map(\.key)) == [key("t2"), otherT2] }
        guard case .action(let receipt)? = mailbox.notice?.undo else {
            Issue.record("Archive left no notice with Undo")
            return
        }
        mailbox.undo(receipt)
        try await waitUntil { mailbox.threads.count == 4 }
        #expect(Set(mailbox.threads.map(\.key)) == keys("t1", "t2").union([otherT1, otherT2]))

        // The Go menu lists every account, even from one account's mailbox,
        // and All Mail combines them like the Inbox.
        mailbox.go(to: SystemLabel.starred)
        #expect(mailbox.selectedMailbox == .combined(SystemLabel.starred))
        mailbox.selectedMailbox = .account("second", SystemLabel.trash)
        mailbox.go(to: SystemLabel.allMail)
        #expect(mailbox.selectedMailbox == .combined(SystemLabel.allMail))
        try await waitUntil { Set(mailbox.threads.map(\.accountID)) == ["audit", "second"] }

        // Signing out of one account keeps Undo for the other's part.
        let manager = UndoManager()
        manager.groupsByEvent = false
        mailbox.undoManager = manager
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        try await waitUntil { mailbox.threads.count == 4 }
        mailbox.selectedThreadIDs = [key("t1"), otherT1]
        await mailbox.perform(.archive)?.value
        await mailbox.removeAccount(id: "second")
        #expect(mailbox.selectedMailbox == .account("audit", SystemLabel.inbox))
        try await waitUntil { mailbox.threads.map(\.key) == [key("t2")] }
        #expect(manager.canUndo)
        manager.undo()
        try await waitUntil { Set(mailbox.threads.map(\.key)) == keys("t1", "t2") }
        await mailbox.stop()
    }

    @Test func searchKeepsEachAccountsResultsAndCoversTheAccountsInView() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let second = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        await mailbox.addAccount(second, gmail: AuditGmail())
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && mailbox.threads.count == 4 }
        let otherT3 = ThreadKey(accountID: "second", threadID: "t3")

        // A combined mailbox searches every account.
        mailbox.search.update("plans")
        try await waitUntil { mailbox.listedThreads.count == 4 }
        mailbox.selectedThreadIDs = [otherT3]
        // Gmail's pages make each account read its results again. Until the
        // second account answers, its earlier results and the selection stay.
        mailbox.search.submit()
        try await waitUntil { mailbox.search.gmail?.state == .finished }
        try await Task.sleep(for: .milliseconds(200))
        #expect(mailbox.selectedThreadIDs == [otherT3])
        #expect(mailbox.listedThreads.count == 4)

        // One account's mailbox searches that account alone.
        mailbox.selectedMailbox = .account("second", SystemLabel.inbox)
        mailbox.search.update("plans")
        try await waitUntil { mailbox.listedThreads.count == 2 }
        #expect(Set(mailbox.listedThreads.map(\.accountID)) == ["second"])
        #expect(!mailbox.listMixesAccounts)
        await mailbox.stop()
    }

    @Test func searchScopeNarrowsToTheMailboxOrOneAccountUntilTheSearchEnds() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let second = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        await mailbox.addAccount(second, gmail: AuditGmail())
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && mailbox.threads.count == 4 }

        // Two letters stay on this Mac, so Gmail can't add mail from outside the scope.
        mailbox.search.update("pl")
        try await waitUntil { mailbox.listedThreads.count == 4 }
        #expect(mailbox.sidebarSelection == nil)
        let scope = try #require(mailbox.searchMailboxScope)
        #expect(scope == MailboxSearchScope(title: "Inbox", restriction: "in:inbox"))
        mailbox.search.restrict(to: scope.restriction)
        try await waitUntil { mailbox.listedThreads.count == 2 }
        #expect(Set(mailbox.listedThreads.map(\.key.threadID)) == ["t2"])
        mailbox.search.restrict(toAccount: "second")
        try await waitUntil { mailbox.listedThreads.count == 1 }
        #expect(mailbox.listedThreads.first?.accountID == "second")
        #expect(!mailbox.listMixesAccounts)

        // Choosing the selected mailbox again ends the search, and the next search starts from all mail.
        mailbox.sidebarSelection = .combined(SystemLabel.inbox)
        #expect(!mailbox.search.isActive)
        #expect(mailbox.search.restriction == nil && mailbox.search.accountID == nil)
        #expect(mailbox.sidebarSelection == .combined(SystemLabel.inbox))
        await mailbox.stop()
    }

    @Test func undoIsAvailableBeforePersistenceAndCommandsHaveSeparateGroups() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory)
        let manager = UndoManager()
        manager.groupsByEvent = false
        mailbox.undoManager = manager
        let first = try #require(mailbox.perform(.archive, on: keys("t1")))
        // Registration belongs to the initiating event, before any await.
        #expect(manager.canUndo)
        #expect(manager.undoActionName == "Archive")
        let second = try #require(mailbox.perform(.markUnread, on: keys("t2")))
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
        for _ in 0..<(MailboxModel.undoLimit + 5) { mailbox.perform(.archive, on: keys("t1")) }
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
        mailbox.selectedMailbox = .account("audit", MailboxModel.outboxID)
        await mailbox.start()
        try await waitUntil { mailbox.hasSyncedOnce && !mailbox.userLabels.isEmpty }
        #expect(mailbox.selectedLabelID == MailboxModel.outboxID)
        #expect(mailbox.threads.isEmpty)

        let id = try #require(await mailbox.startCompose(.newMessage))
        try await mailbox.engine.sendDraft(id, delay: 60)
        try await waitUntil { mailbox.outbox.map(\.id) == [id] }
        #expect(await mailbox.undoSend(id))
        try await waitUntil { mailbox.outbox.isEmpty }
        #expect(mailbox.showsOutbox(.account("audit", MailboxModel.outboxID)))
        mailbox.selectedMailbox = .account("audit", SystemLabel.inbox)
        #expect(!mailbox.showsOutbox(.account("audit", MailboxModel.outboxID)))
        await mailbox.stop()
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition(), "Mailbox observation did not reach the expected state")
}

/// Conversations in the audit account, which every test here uses.
private func key(_ threadID: String) -> ThreadKey {
    ThreadKey(accountID: "audit", threadID: threadID)
}

private func keys(_ threadIDs: String...) -> Set<ThreadKey> {
    Set(threadIDs.map(key))
}
