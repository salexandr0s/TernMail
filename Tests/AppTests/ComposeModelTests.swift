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
        // Choosing the default sender isn't an edit.
        #expect(!model.isEdited)

        model.content.subject = "Plan"
        #expect(model.isEdited)
        try await waitUntil { !model.hasPendingEdits }
        #expect(try await cache.read { try $0.localDraft(id: id) }?.subject == "Plan")

        #expect(await model.send() == false)
        #expect(model.alert == ComposeModel.Problem(title: "Can't Send Message", message: "Add at least one recipient."))

        model.content.to = [EmailAddress(address: "pat@example.com")]
        model.save()
        try await waitUntil { model.status?.text == "Saved to Drafts" }
        #expect(!model.isEdited)

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

        // A normal close asks nothing.
        await model.requestClose()
        #expect(model.phase == .closed && model.alert == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await cache.read({ try $0.localDraft(id: id) }) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await cache.read { try $0.localDraft(id: id) } == nil)
        await mailbox.stop()
    }

    @Test func closingWaitsForTheStoreAndStaysOpenWhenItFails() async throws {
        let file = CacheFile()
        let (mailbox, cache) = try await makeMailbox(in: file)
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        #expect(!model.closesAtOnce)

        try file.refuse("UPDATE", on: "localDraft")
        model.content.subject = "Plan"
        await model.requestClose()
        // Still open, showing the error, with the edit this Mac doesn't have.
        #expect(model.phase == .open && model.isEditable && model.content.subject == "Plan")
        #expect(model.alert?.title == "Can't Close Message" && model.status?.isError == true)
        #expect(try await cache.read { try $0.localDraft(id: id) }?.subject != "Plan")

        try file.allow("UPDATE", on: "localDraft")
        model.alert = nil
        await model.requestClose()
        #expect(model.phase == .closed && model.alert == nil)
        #expect(try await cache.read { try $0.localDraft(id: id) }?.subject == "Plan")
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

    @Test func attachmentsOpenAsCopiesUnderTheirOwnNamesThatGoWithTheWindow() async throws {
        let (mailbox, _) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }

        model.attach([
            .data(Data("agenda".utf8), filename: "agenda.txt", mimeType: "text/plain"),
            .data(Data("notes".utf8), filename: "notes.txt", mimeType: "text/plain"),
        ])
        try await waitUntil { model.attachments.count == 2 }
        let agenda = try #require(model.attachments.first { $0.filename == "agenda.txt" })
        let notes = try #require(model.attachments.first { $0.filename == "notes.txt" })
        let agendaCopy = try #require(await model.attachmentFileURL(agenda))
        let notesCopy = try #require(await model.attachmentFileURL(notes))
        #expect(agendaCopy.lastPathComponent == "agenda.txt")
        #expect(try Data(contentsOf: agendaCopy) == Data("agenda".utf8))

        model.removeAttachment(agenda)
        #expect(!FileManager.default.fileExists(atPath: agendaCopy.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: notesCopy.path(percentEncoded: false)))
        model.windowClosed()
        #expect(!FileManager.default.fileExists(atPath: notesCopy.path(percentEncoded: false)))
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
        #expect(await mailbox.prepareToQuit().isEmpty)
        #expect(try await cache.read { try $0.localDraft(id: id) }?.subject == "Plan")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await cache.read({ try $0.localDraft(id: id) })?.gmailDraftID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await cache.read { try $0.localDraft(id: id) }?.gmailDraftID != nil)
        await mailbox.stop()
    }

    @Test func quittingStopsWhileADraftCanNotBeStored() async throws {
        let file = CacheFile()
        let (mailbox, cache) = try await makeMailbox(in: file)
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }

        try file.refuse("UPDATE", on: "localDraft")
        model.content.subject = "Plan"
        #expect(await mailbox.prepareToQuit() == ["Plan"])
        #expect(model.phase == .open && model.isEditable && model.content.subject == "Plan")

        try file.allow("UPDATE", on: "localDraft")
        #expect(await mailbox.prepareToQuit().isEmpty)
        #expect(try await cache.read { try $0.localDraft(id: id) }?.subject == "Plan")
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

    /// A mailbox whose cache is in memory, or in `file` for a test that breaks it.
    private func makeMailbox(in file: CacheFile? = nil) async throws -> (MailboxModel, MailCache) {
        let cache = try file.map { try MailCache.open(at: $0.url) } ?? MailCache.inMemory()
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
