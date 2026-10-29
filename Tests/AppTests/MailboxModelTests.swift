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
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail())
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

    @Test func undoIsAvailableBeforePersistenceAndCommandsHaveSeparateGroups() async throws {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail())
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
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail())
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
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition(), "Mailbox observation did not reach the expected state")
}
