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

    @Test func promisedAttachmentHoldsSendUntilItsFileArrives() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        model.content.to = [EmailAddress(address: "pat@example.com")]
        let folder = FileManager.default.temporaryDirectory.appending(path: "TernPromisedAttachTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let temporary = folder.appending(path: "provider-content")
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        try bytes.write(to: temporary)
        var gate: CheckedContinuation<URL, any Error>?
        defer { gate?.resume(throwing: CancellationError()) }
        let source = ComposeDroppedFile(filename: "Dinner.png", load: {
            try await withCheckedThrowingContinuation { gate = $0 }
        })

        model.attach([.dropped(source)])
        #expect(model.progressText != nil)
        #expect(await model.send() == false)
        try await waitUntil { gate != nil }
        #expect(try await cache.read { try $0.composeRows(localDraftID: id).filter { $0.kind == .sendDraft }.count } == 0)
        #expect(try await cache.read { try $0.localDraft(id: id) }?.state == .editing)
        gate?.resume(returning: temporary)
        gate = nil
        try await waitUntil { model.attachments.count == 1 && model.progressText == nil }
        let attachment = try #require(model.attachments.first)
        #expect(attachment.filename == "Dinner.png")
        #expect(attachment.contentID == nil)
        let copy = try #require(await model.attachmentFileURL(attachment))
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(await model.send())
        #expect(try await cache.read { try $0.composeRows(localDraftID: id).filter { $0.kind == .sendDraft }.count } == 1)
        #expect(await mailbox.undoSend(id))
        await mailbox.stop()
    }

    @Test func aFileThatFailsToAttachStaysListedAndHoldsSendAndCloseUntilRetried() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        model.content.to = [EmailAddress(address: "pat@example.com")]
        let folder = FileManager.default.temporaryDirectory.appending(path: "TernAttachTests-\(UUID().uuidString)")
        let file = folder.appending(path: "agenda.txt")

        // Not there yet, so copying it in fails.
        model.attach([.file(file)])
        #expect(await model.send() == false)
        #expect(model.alert == ComposeModel.Problem(title: "Can't Send Yet", message: "Wait for “agenda.txt” to finish attaching."))
        try await waitUntil { !model.failedAttachments.isEmpty }
        #expect(model.failedAttachments.map(\.filename) == ["agenda.txt"])
        #expect(await model.send() == false)
        #expect(model.alert?.message == "“agenda.txt” couldn't be attached. Retry or remove it first.")
        await model.requestClose()
        #expect(model.phase == .open && model.alert?.title == "Can't Close Message")
        #expect(try await cache.read { try $0.localDraft(id: id) }?.state == .editing)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("agenda".utf8).write(to: file)
        let failure = try #require(model.failedAttachments.first)
        model.retry(failure)
        try await waitUntil { model.attachments.count == 1 }
        #expect(model.failedAttachments.isEmpty && model.attachments.first?.filename == "agenda.txt")
        #expect(await model.send())
        await mailbox.stop()
    }

    @Test func aFileThatFailsToBeRemovedStaysAttachedAndHoldsSendUntilRetried() async throws {
        let file = CacheFile()
        let (mailbox, _) = try await makeMailbox(in: file)
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        model.content.to = [EmailAddress(address: "pat@example.com")]
        model.attach([.data(Data("agenda".utf8), filename: "agenda.txt", mimeType: "text/plain")])
        try await waitUntil { model.attachments.count == 1 }
        let agenda = try #require(model.attachments.first)

        try file.refuse("DELETE", on: "outgoingAttachment")
        model.removeAttachment(agenda)
        try await waitUntil { !model.failedAttachments.isEmpty }
        #expect(model.failedAttachments.first?.removedID == agenda.id)
        #expect(model.attachments.map(\.id) == [agenda.id])
        #expect(await model.send() == false)
        #expect(model.alert?.message == "“agenda.txt” couldn't be removed. Retry or keep it first.")

        try file.allow("DELETE", on: "outgoingAttachment")
        let failure = try #require(model.failedAttachments.first)
        model.retry(failure)
        try await waitUntil { model.attachments.isEmpty }
        #expect(model.failedAttachments.isEmpty)
        #expect(await model.send())
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

    @Test func pendingGroupProtectsCloseMoveAndQuitUntilRecipientsArrive() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let second = AccountRecord(id: "other", email: "other@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(second, gmail: AuditGmail(.second))
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        model.content.subject = "Group plan"
        model.expandingGroups = 1
        await model.requestClose()
        #expect(model.phase == .open)
        #expect(model.alert?.title == "Recipients Are Still Loading")
        model.move(to: second.id)
        #expect(model.phase == .open)
        #expect(await model.prepareToQuit() == false)
        #expect(try await cache.read { try $0.localDraft(id: id)?.state } == .editing)
        model.content.to = [.init(address: "member@example.invalid")]
        model.expandingGroups = 0
        await model.requestClose()
        #expect(model.phase == .closed)
        #expect(try await cache.read { try $0.localDraft(id: id)?.to.first?.address } == "member@example.invalid")
        await mailbox.stop()
    }

    @Test func failedDiscardExplainsFailureAndRestartsPendingPersistence() async throws {
        let file = CacheFile()
        let (mailbox, cache) = try await makeMailbox(in: file)
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        try file.refuse("INSERT", on: "pendingAction")
        model.content.subject = "Keep after failed discard"
        #expect(await model.discard() == false)
        #expect(model.isEditable && model.phase == .open)
        #expect(model.alert?.title == "Couldn't Discard Draft")
        try file.allow("INSERT", on: "pendingAction")
        try await waitUntil { !model.hasPendingEdits }
        #expect(try await cache.read { try $0.localDraft(id: id)?.subject } == "Keep after failed discard")
        await model.requestClose()
        await mailbox.stop()
    }

    @Test func quotationAndSignatureChangesPersistWithoutChangingThreadingOrDefaults() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let draft = LocalDraft(accountID: "audit", kind: .reply,
            content: DraftContent(to: [.init(address: "pat@example.invalid")], subject: "Reply",
                body: ComposeDocument(plainText: "My answer"), signatureHTML: "<p>Default signature</p>"),
            rfcMessageID: "<quote-editor@example.invalid>", threadID: "original-thread",
            inReplyTo: "<source@example.invalid>", quotedHTML: "<blockquote>Private history</blockquote>",
            quotedPlainText: "Private history", now: .now)
        try await mailbox.cache.write { try $0.insertLocalDraft(draft) }
        let model = ComposeModel(localDraftID: draft.id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        model.isEditingSupplement = true
        #expect(await model.send() == false)
        #expect(await model.replaceQuote(with: "Public excerpt"))
        model.isEditingSupplement = false
        #expect(try await cache.read { try $0.localDraft(id: draft.id)?.quotedPlainText } == "Public excerpt")
        #expect(await model.replaceQuote(with: "  "))
        model.chooseSignature(nil)
        #expect(model.content.signatureHTML == nil)
        model.isEditingSupplement = true
        model.replaceSignature(with: ComposeDocument(plainText: "For this message"))
        await model.requestClose()
        let stored = try #require(try await cache.read { try $0.localDraft(id: draft.id) })
        #expect(stored.quotedHTML == nil && stored.quotedPlainText == nil)
        #expect(stored.signatureHTML?.contains("For this message") == true)
        #expect(stored.body.plainText() == "My answer")
        #expect(stored.threadID == "original-thread" && stored.inReplyTo == "<source@example.invalid>")
        await mailbox.stop()
    }

    @Test func attachmentBudgetUsesEditorDeletionBeforeItsDelayedStore() async throws {
        let (mailbox, _) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        let bytes = Data(count: 14_000_000)
        model.attach([.data(bytes, filename: "large.png", mimeType: "image/png")], inlineImages: true)
        try await waitUntil { model.attachments.count == 1 && model.progressText == nil }
        #expect(model.content.body.blocks.flatMap(\.runs).contains { $0.image != nil })
        model.content.body = ComposeDocument()
        // Attach immediately, before the 500 ms store timer can run.
        model.attach([.data(bytes, filename: "replacement.bin", mimeType: "application/octet-stream")])
        try await waitUntil { model.progressText == nil }
        #expect(model.failedAttachments.isEmpty)
        #expect(model.attachments.count == 2)
        await model.requestClose()
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
