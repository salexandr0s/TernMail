import AppKit
import Foundation
import MailStore
import MessageContent
import SwiftUI
import Testing
@testable import Tern

@Suite @MainActor struct ComposeModelTests {
    @Test(arguments: ["save", "send", "close"])
    func nativeTypingReachesImmediateDraftActionsWithoutAConversionDelay(action: String) async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        model.content.to = [.init(address: "recipient@example.invalid")]
        model.content.subject = "Synthetic large draft"
        model.content.body = ComposeDocument(blocks: (0..<1_000).map { index in
            .init(runs: [.init("Paragraph \(index).", bold: index.isMultiple(of: 2))])
        })
        let editor = RichTextEditor(
            document: Binding(get: { model.content.body }, set: { model.content.body = $0 }),
            format: Binding(get: { model.format }, set: { model.format = $0 }),
            isEditable: true, onReady: { _ in }, onAttach: { _ in }, onFocusChange: { _ in }
        )
        let coordinator = editor.makeCoordinator()
        let textView = ComposeTextView(usingTextLayoutManager: false)
        textView.isEditable = true
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.load(model.content.body)
        model.editor = coordinator
        let storage = try #require(textView.textStorage)
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.insertText(" Latest edit.", replacementRange: textView.selectedRange())
        let expected = AttributedDocument.document(from: storage)
        #expect(model.content.body == expected)
        #expect(model.content.body.blocks.last?.text.hasSuffix(" Latest edit.") == true)

        switch action {
        case "save":
            model.save()
            try await waitUntil { model.status?.text == "Saved to Drafts" }
        case "send":
            #expect(await model.send())
        default:
            await model.requestClose()
        }
        let stored = try #require(try await cache.read { try $0.localDraft(id: id) })
        #expect(stored.body == expected)
        if action == "save" { await model.requestClose() }
        await mailbox.stop()
    }

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

        // A normal close asks nothing and doesn't wait: the window goes at
        // once, and the draft goes after it.
        #expect(model.closesAtOnce)
        model.windowClosed()
        #expect(model.phase == .closed && model.alert == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await cache.read({ try $0.localDraft(id: id) }) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await cache.read { try $0.localDraft(id: id) } == nil)

        // The menu's Reply gets its sender in its window, which isn't an edit
        // either. After a crash macOS restores the window, which opens the
        // reply again, and closing it unchanged still discards it.
        try await waitUntil { mailbox.hasSyncedOnce }
        let replyID = try #require(await mailbox.startCompose(.reply(.reply, messageID: "m1", accountID: "audit")))
        let crashed = ComposeModel(localDraftID: replyID, mailbox: mailbox)
        crashed.start()
        try await waitUntil { crashed.phase == .open }
        let restored = ComposeModel(localDraftID: replyID, mailbox: mailbox)
        restored.start()
        try await waitUntil { restored.phase == .open }
        #expect(restored.content.fromAddress == "audit@example.invalid" && !restored.isEdited)
        await restored.requestClose()
        let closedReply = try await cache.read { try $0.localDraft(id: replyID) }
        #expect(restored.phase == .closed && (closedReply == nil || closedReply?.state == .discarding))
        await mailbox.stop()
    }

    @Test func closingAnUnreviewedAssistantDraftSavesItInsteadOfRemovingIt() async throws {
        let (mailbox, cache) = try await makeMailbox()
        // The assistant leaves its draft on this Mac, so only this save puts it in Gmail Drafts.
        var generated = LocalDraft(accountID: "audit", kind: .new,
            content: DraftContent(to: [.init(address: "pat@example.invalid")], subject: "Proposal",
                body: ComposeDocument(plainText: "Generated reply")),
            rfcMessageID: "<assistant-draft@example.invalid>", now: .now)
        generated.revision = 1
        let draft = generated
        try await mailbox.cache.write { try $0.insertLocalDraft(draft) }
        let model = ComposeModel(localDraftID: draft.id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        await model.requestClose()
        #expect(model.phase == .closed && model.alert == nil)
        let (stored, queued) = try await cache.read { tx in
            (try tx.localDraft(id: draft.id), try tx.pendingActions(accountID: "audit").contains { $0.kind == .saveDraft })
        }
        let kept = try #require(stored)
        #expect(kept.state == .editing && kept.body.plainText() == "Generated reply")
        #expect(queued || kept.gmailDraftID != nil)
        await mailbox.stop()
    }

    @Test func closingWaitsForTheStoreAndStaysOpenWhenItFails() async throws {
        let file = CacheFile()
        let (mailbox, cache) = try await makeMailbox(in: file)
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }

        try file.refuse("UPDATE", on: "localDraft")
        model.content.subject = "Plan"
        #expect(!model.closesAtOnce)
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
        try await waitUntil { !FileManager.default.fileExists(atPath: agendaCopy.path(percentEncoded: false)) }
        #expect(FileManager.default.fileExists(atPath: notesCopy.path(percentEncoded: false)))
        model.windowClosed()
        // The folder is deleted off the main actor, so the copy goes just after the window.
        try await waitUntil { !FileManager.default.fileExists(atPath: notesCopy.path(percentEncoded: false)) }
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
        let previewCopy = try #require(await model.attachmentFileURL(agenda))

        try file.refuse("DELETE", on: "outgoingAttachment")
        model.removeAttachment(agenda)
        try await waitUntil { !model.failedAttachments.isEmpty }
        #expect(model.failedAttachments.first?.removedID == agenda.id)
        #expect(model.attachments.map(\.id) == [agenda.id])
        #expect((try? Data(contentsOf: previewCopy)) == Data("agenda".utf8))
        #expect(await model.send() == false)
        #expect(model.alert?.message == "“agenda.txt” couldn't be removed. Retry or keep it first.")

        try file.allow("DELETE", on: "outgoingAttachment")
        let failure = try #require(model.failedAttachments.first)
        model.retry(failure)
        try await waitUntil { model.attachments.isEmpty }
        try await waitUntil { !FileManager.default.fileExists(atPath: previewCopy.path(percentEncoded: false)) }
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

    @Test func repliesOpenBeforeTheirOriginalLoads() async throws {
        let (mailbox, cache) = try await makeMailbox()
        try await waitUntil { mailbox.hasSyncedOnce }
        // Cached headers with a Message-ID let a reply open without Gmail.
        // Gmail has m1, and no longer has the other message. The cache keeps
        // the newer copy, and the synced m1 is at history 200.
        let headers: [(id: String, thread: String, subject: String, sender: String)] = [
            ("m1", "t1", "Field notes", "River <river@example.invalid>"), ("gone", "t-gone", "Lunch", "pat@example.invalid"),
        ]
        let records = headers.map { header in
            CacheTransaction.MessageUpdate(record: MessageRecord(
                accountID: "audit", id: header.id, threadID: header.thread, historyID: 1_000, date: .now, snippet: "",
                sender: header.sender, recipients: "audit@example.invalid", cc: nil, subject: header.subject,
                sizeEstimate: 1, rfcMessageID: "<\(header.id)@example.invalid>"
            ), labelIDs: [SystemLabel.inbox])
        }
        try await cache.write { tx in _ = try tx.upsertMessages(records) }

        // The forward gets its quote while open, and closing it unchanged still discards it.
        let forwardID = try #require(await mailbox.startCompose(.reply(.forward, messageID: "m1", accountID: "audit")))
        #expect(try await cache.read { try $0.localDraft(id: forwardID) }?.importPending == true)
        let forward = ComposeModel(localDraftID: forwardID, mailbox: mailbox)
        forward.start()
        try await waitUntil { forward.phase == .open && !forward.awaitsOriginal }
        #expect(forward.draft?.quotedPlainText?.contains("field notes") == true)
        await forward.requestClose()
        let closed = try await cache.read { try $0.localDraft(id: forwardID) }
        #expect(forward.phase == .closed && (closed == nil || closed?.state == .discarding))

        // A reply from the reader's buttons gets its sender before the window
        // opens. That isn't an edit, so closing it unchanged discards it too.
        let buttonReplyID = try #require(await mailbox.requestReply(.reply, messageID: "m1", accountID: "audit", selectedText: nil))
        let buttonReply = ComposeModel(localDraftID: buttonReplyID, mailbox: mailbox)
        buttonReply.start()
        try await waitUntil { buttonReply.phase == .open && !buttonReply.awaitsOriginal }
        await buttonReply.requestClose()
        let closedReply = try await cache.read { try $0.localDraft(id: buttonReplyID) }
        #expect(buttonReply.phase == .closed && (closedReply == nil || closedReply?.state == .discarding))

        // A reply whose original won't load waits until it goes without.
        let replyID = try #require(await mailbox.startCompose(.reply(.reply, messageID: "gone", accountID: "audit")))
        let reply = ComposeModel(localDraftID: replyID, mailbox: mailbox)
        reply.start()
        try await waitUntil { reply.phase == .open && reply.originalImportFailed }
        #expect(reply.awaitsOriginal && reply.content.subject == "Re: Lunch")
        #expect(await reply.send() == false)
        #expect(reply.alert == ComposeModel.Problem(title: "Can't Send Message",
                                                    message: "The original message couldn't be loaded. Retry, or leave it out."))
        reply.leaveOutOriginal()
        try await waitUntil { !reply.awaitsOriginal && !reply.originalImportFailed }
        #expect(reply.draft?.quotedPlainText == nil)
        #expect(await reply.send())
        await mailbox.stop()
    }

    @Test func forwardAsAttachmentOpensBeforeItsFileArrives() async throws {
        let (mailbox, cache) = try await makeMailbox()
        try await waitUntil { mailbox.hasSyncedOnce }
        // This Gmail can't give a message's raw copy, so the file never arrives.
        let id = try #require(await mailbox.startForwardingAttachment(messageID: "m1", accountID: "audit"))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open && model.originalImportFailed }
        #expect(model.awaitsOriginal && model.content.subject == "Fwd: Field notes" && !model.isEdited)
        let hold = "“Forwarded Message.eml” couldn't be attached. Retry, or leave it out."
        #expect(await model.send() == false)
        #expect(model.alert == ComposeModel.Problem(title: "Can't Send Message", message: hold))

        // The other account can't download the message either, so it stays here.
        let second = AccountRecord(id: "second", email: "second@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(second, gmail: AuditGmail(.second))
        model.move(to: "second")
        try await waitUntil { model.phase == .open }
        #expect(model.alert == ComposeModel.Problem(title: "Can't Change Account", message: hold))
        #expect(try await cache.read { try $0.localDraft(id: id) }?.accountID == "audit")

        // Closing it unchanged discards it, as it does a forward.
        await model.requestClose()
        let closed = try await cache.read { try $0.localDraft(id: id) }
        #expect(model.phase == .closed && (closed == nil || closed?.state == .discarding))
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

    @Test func anUpdateFromGmailShowsTheCcAndBccRowsItFills() async throws {
        let (mailbox, cache) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        #expect(!model.showsCc && !model.showsBcc)
        // Stored as DraftImport stores a draft another app changed.
        var content = model.content
        content.cc = [EmailAddress(address: "cc@example.invalid")]
        content.bcc = [EmailAddress(address: "bcc@example.invalid")]
        let changed = content
        try await cache.write { _ = try $0.updateLocalDraft(id: id, content: changed, now: .now.addingTimeInterval(60)) }
        try await waitUntil { model.content.cc == changed.cc }
        #expect(model.showsCc && model.showsBcc)
        await model.requestClose()
        await mailbox.stop()
    }

    @Test func insertingAnInlineImageDoesNotReloadTheEditor() async throws {
        let (mailbox, _) = try await makeMailbox()
        let id = try #require(await mailbox.startCompose(.newMessage))
        let model = ComposeModel(localDraftID: id, mailbox: mailbox)
        model.start()
        try await waitUntil { model.phase == .open }
        // SwiftUI hands the coordinator a new editor, with the model's images, on each update.
        func editor(images: [String: Data]) -> RichTextEditor {
            RichTextEditor(
                document: Binding(get: { model.content.body }, set: { model.content.body = $0 }),
                format: Binding(get: { model.format }, set: { model.format = $0 }),
                isEditable: true, inlineImages: images, onReady: { _ in }, onAttach: { _ in }, onFocusChange: { _ in }
            )
        }
        let coordinator = editor(images: model.inlineImageData).makeCoordinator()
        let textView = ComposeTextView(usingTextLayoutManager: false)
        textView.isEditable = true
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.load(model.content.body)
        model.editor = coordinator
        let storage = try #require(textView.textStorage)
        func attachments() -> [NSTextAttachment] {
            var found: [NSTextAttachment] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { found.append(attachment) }
            }
            return found
        }

        let bytes = Data(repeating: 7, count: 64)
        model.attach([.data(bytes, filename: "dot.png", mimeType: "image/png")], inlineImages: true)
        try await waitUntil { model.content.body.blocks.flatMap(\.runs).contains { $0.image != nil } }
        let inserted = try #require(attachments().first)
        // Reloading would replace the text, and Undo with it.
        coordinator.parent = editor(images: model.inlineImageData)
        coordinator.update(model.content.body)
        #expect(attachments().count == 1 && attachments().first === inserted)

        // Data that arrives for an image shown without it still loads. The
        // attachment takes the image's size then, so its size shows whether
        // the data loaded.
        let later = InlineImageReference(contentID: "later@example.invalid", altText: "Later")
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(pixels.representation(using: .png, properties: [:]))
        let imageSize = CGSize(width: 40, height: 30)
        var document = model.content.body
        document.blocks.append(.init(runs: [.init("", image: later)]))
        coordinator.update(document)
        #expect(attachments().last?.bounds.size != imageSize)
        coordinator.parent = editor(images: model.inlineImageData.merging([later.contentID: png]) { $1 })
        coordinator.update(document)
        #expect(attachments().last?.bounds.size == imageSize)
        await model.requestClose()
        await mailbox.stop()
    }

    /// A compose window gets keys before its fields can take them. They go to
    /// that window, in the order typed, once one of its fields has the cursor.
    /// A shortcut and another window's keys are left alone, and the keys are
    /// dropped when no field has the cursor or the window closes.
    @Test func keysTypedBeforeAFieldHasTheCursorAreTypedIntoIt() async throws {
        let compose = TypeAheadTestWindow(), other = TypeAheadTestWindow()
        let field = NSTextView()
        let typeAhead = ComposeTypeAhead()
        typeAhead.attach(to: compose)
        defer { typeAhead.attach(to: nil) }

        let shortcut = try key("w", modifiers: .command, in: compose)
        #expect(typeAhead.monitoredEventHandler(shortcut) === shortcut)
        let elsewhere = try key("x", in: other)
        #expect(typeAhead.monitoredEventHandler(elsewhere) === elsewhere)
        let first = try key("h", in: compose), second = try key("i", in: compose)
        #expect(typeAhead.monitoredEventHandler(first) == nil)
        #expect(typeAhead.monitoredEventHandler(second) == nil)
        // The cursor reaches a field a moment after it is sent there. Keys
        // typed in that moment are kept too.
        typeAhead.release(waitingForCursor: true)
        #expect(compose.sent.isEmpty)
        let third = try key("!", in: compose)
        #expect(typeAhead.monitoredEventHandler(third) == nil)
        compose.reportedFirstResponder = field
        // The kept keys aren't typed yet, so a key that comes now goes after them.
        let fourth = try key(".", in: compose)
        #expect(typeAhead.monitoredEventHandler(fourth) == nil)
        try await waitUntil { compose.sent.count == 4 }
        #expect(compose.sent.elementsEqual([first, second, third, fourth]) { $0 === $1 })
        // The field has the cursor, so it gets its own keys from here on.
        let later = try key("?", in: compose)
        #expect(typeAhead.monitoredEventHandler(later) === later)

        // The fields take nothing during a move. No field has the cursor
        // when it ends here, so what was typed meanwhile is dropped.
        compose.reportedFirstResponder = nil
        typeAhead.hold()
        #expect(typeAhead.monitoredEventHandler(try key("z", in: compose)) == nil)
        typeAhead.release(waitingForCursor: false)
        compose.reportedFirstResponder = field
        #expect(typeAhead.monitoredEventHandler(later) === later)

        // A window that closes drops what it kept and keeps nothing more.
        compose.reportedFirstResponder = nil
        typeAhead.hold()
        #expect(typeAhead.monitoredEventHandler(try key("q", in: compose)) == nil)
        typeAhead.attach(to: nil)
        compose.reportedFirstResponder = field
        typeAhead.release(waitingForCursor: false)
        #expect(typeAhead.monitoredEventHandler(later) === later)
        #expect(compose.sent.count == 4 && other.sent.isEmpty)
    }

    /// A command makes the draft before its window opens, so the keys typed
    /// meanwhile go to the window in front. They are kept for the draft's
    /// window, until it takes the keyboard, and typed into it with its own.
    /// A draft that can't be made takes them with it.
    @Test func keysTypedBeforeTheWindowOpensGoToIt() throws {
        let main = TypeAheadTestWindow(), compose = TypeAheadTestWindow()
        let opening = ComposeTypeAhead.catchKeys(from: main)
        defer { opening.drop() }
        #expect(ComposeTypeAhead.keepsKeys(typedIn: main) && !ComposeTypeAhead.keepsKeys(typedIn: compose))
        let shortcut = try key("n", modifiers: .command, in: main)
        #expect(opening.monitoredEventHandler(shortcut) === shortcut)
        #expect(opening.monitoredEventHandler(try key("h", in: main)) == nil)

        opening.wait(for: "opening-draft")
        let typeAhead = ComposeTypeAhead()
        typeAhead.attach(to: compose, takingKeysFor: "opening-draft")
        defer { typeAhead.attach(to: nil) }
        #expect(typeAhead.monitoredEventHandler(try key("i", in: main)) == nil)
        #expect(typeAhead.monitoredEventHandler(try key("!", in: compose)) == nil)
        // The window has the keyboard now, so the other one gets its keys again.
        let back = try key("x", in: main)
        #expect(typeAhead.monitoredEventHandler(back) === back)
        #expect(!ComposeTypeAhead.keepsKeys(typedIn: main))

        compose.reportedFirstResponder = NSTextView()
        typeAhead.release(waitingForCursor: false)
        #expect(compose.sent.map(\.characters) == ["h", "i", "!"])
        #expect(compose.sent.allSatisfy { $0.window === compose } && main.sent.isEmpty)

        let failed = ComposeTypeAhead.catchKeys(from: main)
        #expect(failed.monitoredEventHandler(try key("q", in: main)) == nil)
        failed.drop()
        let after = try key("w", in: main)
        #expect(failed.monitoredEventHandler(after) === after)
        #expect(!ComposeTypeAhead.keepsKeys(typedIn: main))
    }

    /// A mail link or another app can open a compose window while Tern isn't
    /// in front, so the keys typed meanwhile can reach any of its windows.
    /// They are kept for the new window, except those typed where a field
    /// has the cursor, in another compose window or in a panel.
    @Test func keysTypedInAnyWindowWhileALinkOpensAMessageGoToIt() throws {
        let main = TypeAheadTestWindow(), reader = TypeAheadTestWindow(), compose = TypeAheadTestWindow()
        let other = TypeAheadTestWindow()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
            styleMask: .borderless, backing: .buffered, defer: false)
        let otherTypeAhead = ComposeTypeAhead()
        otherTypeAhead.attach(to: other)
        defer { otherTypeAhead.attach(to: nil) }
        let opening = ComposeTypeAhead.catchKeysInAnyWindow()
        defer { opening.drop() }
        #expect(ComposeTypeAhead.keepsKeys(typedIn: main) && ComposeTypeAhead.keepsKeys(typedIn: reader))
        let shortcut = try key("n", modifiers: .command, in: main)
        #expect(opening.monitoredEventHandler(shortcut) === shortcut)
        #expect(opening.monitoredEventHandler(try key("h", in: main)) == nil)
        reader.reportedFirstResponder = NSTextView()
        let typing = try key("x", in: reader)
        #expect(opening.monitoredEventHandler(typing) === typing)
        reader.reportedFirstResponder = nil
        #expect(opening.monitoredEventHandler(try key("e", in: reader)) == nil)
        for window in [other, panel] as [NSWindow] {
            let own = try key("y", in: window)
            #expect(opening.monitoredEventHandler(own) === own)
        }

        opening.wait(for: "linked-draft")
        let typeAhead = ComposeTypeAhead()
        typeAhead.attach(to: compose, takingKeysFor: "linked-draft")
        defer { typeAhead.attach(to: nil) }
        // Keys typed elsewhere reach the new window until it takes the keyboard.
        #expect(typeAhead.monitoredEventHandler(try key("l", in: reader)) == nil)
        #expect(typeAhead.monitoredEventHandler(try key("o", in: compose)) == nil)
        let back = try key("z", in: main)
        #expect(typeAhead.monitoredEventHandler(back) === back)
        #expect(!ComposeTypeAhead.keepsKeys(typedIn: main))

        compose.reportedFirstResponder = NSTextView()
        typeAhead.release(waitingForCursor: false)
        #expect(compose.sent.map(\.characters) == ["h", "e", "l", "o"])
        #expect(compose.sent.allSatisfy { $0.window === compose })
        #expect(main.sent.isEmpty && reader.sent.isEmpty && other.sent.isEmpty)
    }

    /// Edit Draft on a draft whose window is open only brings that window
    /// forward, so it never attaches again. It takes the keys the command
    /// kept once it has the keyboard, ahead of the ones typed in it meanwhile.
    @Test func keysTypedForADraftWhoseWindowIsOpenGoToItOnceItIsKey() async throws {
        let main = TypeAheadTestWindow(), compose = TypeAheadTestWindow()
        let typeAhead = ComposeTypeAhead()
        typeAhead.attach(to: compose, takingKeysFor: "open-draft")
        defer { typeAhead.attach(to: nil) }
        compose.reportedFirstResponder = NSTextView()
        typeAhead.release(waitingForCursor: false)

        let opening = ComposeTypeAhead.catchKeys(from: main)
        defer { opening.drop() }
        #expect(opening.monitoredEventHandler(try key("h", in: main)) == nil)
        opening.wait(for: "open-draft")
        // Keys typed in the other window are kept until this one gets one of its own.
        #expect(typeAhead.monitoredEventHandler(try key("e", in: main)) == nil)
        #expect(typeAhead.monitoredEventHandler(try key("l", in: compose)) == nil)
        let back = try key("z", in: main)
        #expect(typeAhead.monitoredEventHandler(back) === back)
        #expect(compose.sent.isEmpty)

        compose.reportedIsKey = true
        try await waitUntil { compose.sent.count == 3 }
        #expect(compose.sent.map(\.characters) == ["h", "e", "l"])
        let typed = try key("o", in: compose)
        #expect(typeAhead.monitoredEventHandler(typed) === typed)
    }

    /// A double click can run a command twice for one draft. Its window gets
    /// the keys both runs kept, in the order they were typed.
    @Test func aDraftOpenedTwiceGetsTheKeysOfBothCommands() throws {
        let main = TypeAheadTestWindow(), compose = TypeAheadTestWindow()
        let first = ComposeTypeAhead.catchKeys(from: main), second = ComposeTypeAhead.catchKeys(from: main)
        defer { first.drop(); second.drop() }
        #expect(first.monitoredEventHandler(try key("h", in: main, at: 1)) == nil)
        #expect(second.monitoredEventHandler(try key("e", in: main, at: 2)) == nil)
        #expect(first.monitoredEventHandler(try key("y", in: main, at: 3)) == nil)
        first.wait(for: "clicked-twice")
        second.wait(for: "clicked-twice")

        let typeAhead = ComposeTypeAhead()
        typeAhead.attach(to: compose, takingKeysFor: "clicked-twice")
        defer { typeAhead.attach(to: nil) }
        compose.reportedFirstResponder = NSTextView()
        typeAhead.release(waitingForCursor: false)
        #expect(compose.sent.map(\.characters) == ["h", "e", "y"])
    }

    /// The editor draws a preview of an inline image that was decoded
    /// beforehand. Copying the image out still gives the data that was attached.
    @Test func copyingAnInlineImageGivesTheDataThatWasAttached() async throws {
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 640,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(pixels.representation(using: .png, properties: [:]))
        let width = Tokens.Layout.attachmentWidth
        let preview = try #require(await ComposeImagePreview.decoded(
            from: png, display: ComposeImagePreview.Display(maxWidth: width, scale: 2)))
        // As wide as the editor shows an image, with a pixel for each one on the screen.
        #expect(preview.size == CGSize(width: width, height: width * 640 / 960))
        #expect(CGFloat(preview.image.width) == width * 2)
        #expect(preview.typeIdentifier == "public.png")
        let reference = InlineImageReference(contentID: "copied@example.invalid", altText: "Copied")
        var document = ComposeDocument()
        document.blocks.append(.init(runs: [.init("", image: reference)]))
        // With the preview, and as an image whose preview hasn't been made.
        let cases: [[String: ComposeImagePreview]] = [[reference.contentID: preview], [:]]
        for previews in cases {
            let textView = ComposeTextView(usingTextLayoutManager: false)
            textView.importsGraphics = false
            let storage = try #require(textView.textStorage)
            storage.setAttributedString(AttributedDocument.string(
                from: document, inlineImages: [reference.contentID: png], previews: previews))
            var shown: [CGSize] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { shown.append(attachment.bounds.size) }
            }
            #expect(shown == [preview.size])
            textView.setSelectedRange(NSRange(location: 0, length: storage.length))
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            // These are the types Copy writes.
            #expect(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
            let copied = try #require(pasteboard.data(forType: .rtfd).flatMap { NSAttributedString(rtfd: $0, documentAttributes: nil) })
            var files: [Data?] = []
            copied.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copied.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { files.append(attachment.fileWrapper?.regularFileContents) }
            }
            #expect(files == [png])
        }
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

    private func key(_ character: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow,
                     at timestamp: TimeInterval = 1) throws -> NSEvent {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 6))
        try #require(event.window === window)
        return event
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "The compose window did not reach the expected state")
    }
}

/// Never ordered onscreen. It reports the first responder and key state a
/// test gives it and records the keys it is sent, so a test neither takes
/// the keyboard nor relies on AppKit delivering keys to a window that isn't
/// shown.
@MainActor private final class TypeAheadTestWindow: NSWindow {
    var reportedFirstResponder: NSResponder?
    var reportedIsKey = false
    private(set) var sent: [NSEvent] = []
    override var firstResponder: NSResponder? { reportedFirstResponder }
    override var isKeyWindow: Bool { reportedIsKey }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
            styleMask: .borderless, backing: .buffered, defer: false)
    }

    override func sendEvent(_ event: NSEvent) {
        sent.append(event)
    }
}
