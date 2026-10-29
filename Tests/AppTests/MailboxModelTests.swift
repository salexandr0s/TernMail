import AppKit
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct MailboxModelTests {
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
