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
