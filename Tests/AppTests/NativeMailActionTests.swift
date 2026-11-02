import Foundation
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct NativeMailActionTests {
    @Test func detachedMessageActionsIgnoreTheMainSelectionAndKeepSiblingMail() async throws {
        let (mailbox, cache) = try await fixture()
        mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "other")]
        let undo = UndoManager()
        let receipt = try #require(await mailbox.performNativeAction(.archive,
            link: MailLink(accountID: "a", threadID: "t", messageID: "m1"), undoManager: undo))
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"]?.contains(SystemLabel.inbox) == false)
        #expect(labels["m2"]?.contains(SystemLabel.inbox) == true)
        let other = try await cache.read { try $0.currentLabels(threadID: "other", accountID: "a") }
        #expect(other["m3"]?.contains(SystemLabel.inbox) == true)
        #expect(undo.canUndo)
        try await mailbox.account(id: "a")?.engine.undo(receipt)
        #expect(try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a")["m1"]?.contains(SystemLabel.inbox) } == true)
        await mailbox.stop()
    }

    @Test func aMessageFromAnotherThreadCannotBroadenTheDisplayedLink() async throws {
        let (mailbox, cache) = try await fixture()
        let result = await mailbox.performNativeAction(.trash,
            link: MailLink(accountID: "a", threadID: "t", messageID: "m3"), undoManager: nil)
        #expect(result == nil)
        #expect(await mailbox.nativeReplyMessageID(for: MailLink(accountID: "a", threadID: "t", messageID: "m3")) == nil)
        #expect(await mailbox.nativeReplyMessageID(for: MailLink(accountID: "a", threadID: "t", messageID: "m1"), preferredMessageID: "m3") == nil)
        #expect(await mailbox.nativeReplyMessageID(for: MailLink(accountID: "a", threadID: "t", messageID: "m1")) == "m1")
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").isEmpty })
        await mailbox.stop()
    }

    @Test func mailLinksKeepTrashScopeAndOpenIndependentlyOfListSelection() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let readinessDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !mailbox.hasSyncedOnce, ContinuousClock.now < readinessDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(mailbox.hasSyncedOnce)
        let accountID = mailbox.defaultAccount.account.id
        let link = MailLink(accountID: accountID, threadID: "linked-trash", messageID: "linked-message")
        try await mailbox.cache.write { tx in
            _ = try tx.upsertMessages([.init(record: MessageRecord(accountID: accountID, id: "linked-message",
                threadID: "linked-trash", historyID: 1, date: .distantPast, snippet: "", sender: "sender@example.invalid",
                recipients: "audit@example.invalid", cc: nil, subject: "Linked mail", sizeEstimate: 10), labelIDs: [SystemLabel.trash])])
            try tx.rebuildThreads(["linked-trash"], accountID: accountID)
        }
        app.mailURLs.receive(try #require(link.ternURL))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while app.mailURLs.conversationWindowLink == nil, app.mailURLs.error == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(app.mailURLs.error == nil)
        #expect(mailbox.selectedMailbox == .account(accountID, SystemLabel.trash))
        #expect(app.mailURLs.conversationWindowLink == link)
        mailbox.selectedThreadIDs = []
        #expect(app.mailURLs.conversationWindowLink == link)
        await app.prepareToQuit()
        await mailbox.stop()
        app.accountPreferences?.stop()
    }

    @Test func assistantCitationsPreserveExactAttachmentInBothWindowsWithoutOnlineLoading() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !mailbox.hasSyncedOnce, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(mailbox.hasSyncedOnce)
        let accountID = mailbox.defaultAccount.account.id
        let source = AssistantSource(accountID: accountID, threadID: "cited-thread", messageID: "cited-message",
                                     partID: "1.2", title: "Cited file")
        let link = MailLink(accountID: accountID, threadID: source.threadID, messageID: source.messageID, partID: source.partID)
        try await mailbox.cache.write { tx in
            _ = try tx.upsertMessages([.init(record: MessageRecord(accountID: accountID, id: "cited-message",
                threadID: "cited-thread", historyID: 1, date: .distantPast, snippet: "", sender: "sender@example.invalid",
                recipients: "audit@example.invalid", cc: nil, subject: "Cited file", sizeEstimate: 10), labelIDs: [SystemLabel.trash])])
            try tx.rebuildThreads(["cited-thread"], accountID: accountID)
            try tx.replaceAttachments([.init(accountID: accountID, messageID: "cited-message", partID: "1.2",
                attachmentID: "file", filename: "Source.pdf", mimeType: "application/pdf", size: 10, isInline: false)],
                messageID: "cited-message", accountID: accountID)
        }
        app.assistant.setAccountEnabled(accountID, enabled: true)
        // A stopped engine proves cached citations do not need a network fetch.
        await mailbox.defaultAccount.engine.stop()
        let selection = mailbox.selectedMailbox
        app.openAssistantSource(source)
        await app.assistantNavigationTask?.value
        #expect(app.mailURLs.conversationWindowLink == link)
        #expect(mailbox.selectedMailbox == selection)
        mailbox.selectedThreadIDs = []
        #expect(app.mailURLs.conversationWindowLink == link)
        var detached: MailLink?
        app.openAssistantSourceInNewWindow(source) { detached = $0 }
        await app.assistantNavigationTask?.value
        #expect(detached == link)

        app.assistant.setAccountEnabled(accountID, enabled: false)
        detached = nil
        app.openAssistantSourceInNewWindow(source) { detached = $0 }
        await app.assistantNavigationTask?.value
        #expect(detached == nil)
        await app.prepareToQuit()
        await mailbox.stop()
        app.accountPreferences?.stop()
    }

    @Test func sourceResolutionRechecksAuthorizationAfterAttachmentHydration() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !mailbox.hasSyncedOnce, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(mailbox.hasSyncedOnce)
        let accountID = mailbox.defaultAccount.account.id
        try await mailbox.cache.write { tx in
            try tx.replaceAttachments([], messageID: "m3", accountID: accountID)
        }
        let link = MailLink(accountID: accountID, threadID: "t2", messageID: "m3", partID: "1")
        var accessChecks = 0
        await #expect(throws: CancellationError.self) {
            _ = try await app.mailURLs.resolveConversation(link) {
                accessChecks += 1
                return accessChecks < 4
            }
        }
        #expect(accessChecks == 4)
        #expect(app.mailURLs.conversationWindowLink == nil)
        #expect(try await mailbox.cache.read { try $0.attachments(messageID: "m3", accountID: accountID).contains { $0.partID == "1" } })
        #expect(try await app.mailURLs.resolveConversation(link) == link)
        let wrongMessage = MailLink(accountID: accountID, threadID: "t2", messageID: "m1")
        await #expect(throws: (any Error).self) { _ = try await app.mailURLs.resolveConversation(wrongMessage) }
        await app.prepareToQuit()
        await mailbox.stop()
        app.accountPreferences?.stop()
    }

    private func fixture() async throws -> (MailboxModel, MailCache) {
        let account = AccountRecord(id: "a", email: "me@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            _ = try tx.upsertMessages([("m1", "t"), ("m2", "t"), ("m3", "other")].map { id, thread in
                CacheTransaction.MessageUpdate(record: MessageRecord(accountID: "a", id: id, threadID: thread,
                    historyID: 1, date: .now, snippet: "", sender: "sender@example.invalid", recipients: account.email,
                    cc: nil, subject: id, sizeEstimate: 10), labelIDs: [SystemLabel.inbox])
            })
        }
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), snoozeStore: nil,
            syncEnabled: false)
        return (mailbox, cache)
    }
}
