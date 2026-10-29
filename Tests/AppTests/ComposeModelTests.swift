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
        #expect(try await mailbox.engine.undoSend(id))
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

        model.attach([.data(Data("agenda".utf8), filename: "agenda.txt", mimeType: "text/plain")])
        try await waitUntil { model.attachments.map(\.filename) == ["agenda.txt"] }
        model.windowClosed()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try await cache.read({ try $0.localDraft(id: id) })?.gmailDraftID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await cache.read { try $0.localDraft(id: id) }?.gmailDraftID != nil)
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
