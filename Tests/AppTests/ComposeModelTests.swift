import Foundation
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct ComposeModelTests {
    @Test func editsAreStoredOnThisMacThenSavedAndSent() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }

        model.content.subject = "Plan"
        try await waitUntil { !model.hasPendingEdits }
        #expect(try await cache.read { try $0.localDraft(id: id) }?.subject == "Plan")

        #expect(await model.send() == false)
        #expect(model.alert == "Add at least one recipient.")

        model.content.to = [EmailAddress(address: "pat@example.com")]
        model.save()
        try await waitUntil { model.status?.text == "Saved to Drafts" }

        #expect(await model.send())
        #expect(model.phase == .closed)
        #expect(try await cache.read { try $0.localDraft(id: id) }?.state == .sending)
        #expect(mailbox.undoableSendID == id)
        #expect(await mailbox.undoSend(id))
        #expect(mailbox.sendNotice == nil && mailbox.undoableSendID == nil)
        #expect(try await cache.read { try $0.localDraft(id: id) }?.state == .editing)
        await mailbox.stop()
    }

    @Test func closingAnUntouchedMessageRemovesIt() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }

        model.windowClosed()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await cache.read({ try $0.localDraft(id: id) }) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await cache.read { try $0.localDraft(id: id) } == nil)
        await mailbox.stop()
    }

    @Test func closingAMessageWithOnlyAnAttachmentSavesIt() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }

        // Closed while the file is still being copied in.
        model.attach([.data(Data("agenda".utf8), filename: "agenda.txt", mimeType: "text/plain")])
        model.windowClosed()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await cache.read({ try $0.localDraft(id: id) })?.gmailDraftID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await cache.read { try $0.localDraft(id: id) }?.gmailDraftID != nil)
        await mailbox.stop()
    }

    @Test func undoingADiscardBringsBackTheLastEdits() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }

        model.content.subject = "Plan"
        #expect(await model.discard())
        #expect(await mailbox.undoDiscard(id))
        #expect(try await cache.read { try $0.localDraft(id: id) }?.subject == "Plan")
        await mailbox.stop()
    }

    @Test func quittingStoresAnOpenDraftAndSavesItToGmail() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }

        model.content.subject = "Plan"
        await mailbox.prepareToQuit()
        #expect(try await cache.read { try $0.localDraft(id: id) }?.subject == "Plan")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await cache.read({ try $0.localDraft(id: id) })?.gmailDraftID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await cache.read { try $0.localDraft(id: id) }?.gmailDraftID != nil)
        await mailbox.stop()
    }

    @Test func repliesAndNewMessagesStayInTheirOwnAccount() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let second = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(second, gmail: AuditGmail(.second))
        try await waitUntil { mailbox.hasSyncedOnce }

        mailbox.selectedMailbox = .account("second", SystemLabel.inbox)
        let newID = try #require(await mailbox.startCompose(.newMessage))
        #expect(try await cache.read { try $0.localDraft(id: newID) }?.accountID == "second")

        // Both accounts hold a message m1. The reply answers the second account's.
        let replyID = try #require(await mailbox.startCompose(.reply(.reply, messageID: "m1", accountID: "second")))
        let model = ComposeModel(localDraftID: replyID, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        #expect(model.content.subject == "Re: Book club")
        #expect(try await cache.read { try $0.localDraft(id: replyID) }?.accountID == "second")

        #expect(await model.send())
        #expect(await mailbox.undoSend(replyID))
        #expect(try await cache.read { try $0.localDraft(id: replyID) }?.state == .editing)
        await mailbox.stop()
    }

    @Test func aNewMessageMovesToAnotherAccountWithTheWindowsEdits() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let second = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(second, gmail: AuditGmail(.second))
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        #expect(model.showsFrom && model.canChangeAccount && model.fromEmail == "audit@example.invalid")

        // Typed, and not yet stored on this Mac.
        model.content.subject = "Plan"
        model.move(to: "second")
        // Nothing can change while the copy is made.
        #expect(model.phase == .moving && !model.isEditable)
        try await waitUntil { model.phase != .moving }
        guard case .moved(let movedID) = model.phase else {
            Issue.record("The message didn't move")
            return
        }
        let moved = try #require(try await cache.read { try $0.localDraft(id: movedID) })
        #expect(moved.accountID == "second" && moved.subject == "Plan")
        let original = try await cache.read { try $0.localDraft(id: id) }
        #expect(original == nil || original?.state == .discarding)
        await mailbox.stop()
    }

    private func makeMailbox() async throws -> (MailboxModel, MailCache) {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "audit", email: "audit@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let outgoing = FileManager.default.temporaryDirectory.appending(path: "TernComposeTests-\(UUID().uuidString)")
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: outgoing)
        await mailbox.start()
        return (mailbox, cache)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "The compose window did not reach the expected state")
    }
}
