import Foundation
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct ConversationDropTests {
    @Test func movingOneMessagePreservesItsSiblingAndCanBeUndone() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let undo = UndoManager()
        mailbox.undoManager = undo
        let item = drag(account: "a", message: "m1", source: SystemLabel.inbox)
        let task = try #require(mailbox.queueDrop([item], on: .account("a", "target")))
        await task.value
        #expect(try await labels("m1", account: "a", in: cache) == ["source", "tag", "target"])
        #expect(try await labels("m2", account: "a", in: cache) == [SystemLabel.inbox, "source", "tag"])
        #expect(undo.canUndo)
        guard case .action(let receipt)? = mailbox.notice?.undo else {
            Issue.record("The completed move must offer Undo.")
            return
        }
        try await mailbox.engine.undo(receipt)
        #expect(try await labels("m1", account: "a", in: cache) == [SystemLabel.inbox, "source", "tag"])
    }

    @Test func optionDragAppliesATagWithoutRemovingInboxOrTheSourceFolder() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let task = try #require(mailbox.queueDrop([drag(account: "a", message: "m1", source: "source")],
                                                on: .account("a", "target"), copy: true))
        await task.value
        #expect(try await labels("m1", account: "a", in: cache) == [SystemLabel.inbox, "source", "tag", "target"])
        #expect(try await labels("m2", account: "a", in: cache) == [SystemLabel.inbox, "source", "tag"])
    }

    @Test func dragSnapshotKeepsItsMessageAndSourceAfterNavigationAndDisplayChanges() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        mailbox.listPreferences.conversations = false
        mailbox.selectedMailbox = .account("a", "source")
        let row = MailListRowID(accountID: "a", threadID: "t", messageID: "m1")
        let items = mailbox.dragItems(for: [row])
        mailbox.selectedMailbox = .account("a", "tag")
        mailbox.listPreferences.conversations = true
        let task = try #require(mailbox.queueDrop(items, on: .account("a", "target")))
        await task.value
        #expect(items.first?.link.messageID == "m1")
        #expect(items.first?.sourceLabelID == "source")
        #expect(try await labels("m1", account: "a", in: cache) == ["tag", "target"])
        #expect(try await labels("m2", account: "a", in: cache) == [SystemLabel.inbox, "source", "tag"])
    }

    @Test func mixedAccountDropIsRejectedWholeButCombinedTrashAcceptsEveryAccount() async throws {
        let (mailbox, cache) = try await fixture(twoAccounts: true)
        defer { Task { await mailbox.stop() } }
        let items = ["a", "b"].map { drag(account: $0, message: "m1", source: SystemLabel.inbox) }
        #expect(mailbox.queueDrop(items, on: .account("a", "target")) == nil)
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").isEmpty })
        #expect(try await cache.read { try $0.pendingActions(accountID: "b").isEmpty })
        let task = try #require(mailbox.queueDrop(items, on: .combined(SystemLabel.trash)))
        await task.value
        for accountID in ["a", "b"] {
            let changed = try await labels("m1", account: accountID, in: cache)
            #expect(changed.contains(SystemLabel.trash))
            #expect(!changed.contains(SystemLabel.inbox))
            #expect(try await labels("m2", account: accountID, in: cache) == [SystemLabel.inbox, "source", "tag"])
        }
    }

    @Test(arguments: [SystemLabel.inbox, SystemLabel.allMail], [SystemLabel.trash, SystemLabel.spam])
    func searchDropsRestoreHiddenMail(destination: String, hiddenLabel: String) async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        try await cache.write { tx in
            _ = try tx.applyLabelChange(messageID: "m1", added: [hiddenLabel], removed: [SystemLabel.inbox],
                                       historyID: 2, accountID: "a")
        }
        mailbox.search.update("Notes")
        let items = mailbox.dragItems(for: [.init(accountID: "a", threadID: "t", messageID: "m1")])
        #expect(items.first?.sourceLabelID == nil)
        let task = try #require(mailbox.queueDrop(items, on: .combined(destination)))
        await task.value
        let changed = try await labels("m1", account: "a", in: cache)
        #expect(!changed.contains(SystemLabel.trash) && !changed.contains(SystemLabel.spam))
        #expect(changed.contains(SystemLabel.inbox) == (destination == SystemLabel.inbox))
        #expect(changed.contains("source") && changed.contains("tag"))
        #expect(try await labels("m2", account: "a", in: cache) == [SystemLabel.inbox, "source", "tag"])
    }

    @Test func unsupportedAndAmbiguousDropsDoNotQueueChanges() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let message = drag(account: "a", message: "m1", source: SystemLabel.inbox)
        let thread = ConversationDragItem(MailLink(accountID: "a", threadID: "t"), sourceLabelID: SystemLabel.inbox)
        #expect(mailbox.queueDrop([message], on: .account("a", SystemLabel.draft)) == nil)
        #expect(mailbox.queueDrop([message, thread], on: .account("a", "target")) == nil)
        #expect(mailbox.queueDrop([message, drag(account: "a", message: "m2", source: "source")],
                                  on: .account("a", "target")) == nil)
        #expect(mailbox.queueDrop([message], on: .account("a", SystemLabel.inbox)) == nil)
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").isEmpty })
    }

    @Test func mismatchedMessageAndConversationCannotChangeMail() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let wrong = ConversationDragItem(MailLink(accountID: "a", threadID: "other", messageID: "m1"),
                                         sourceLabelID: SystemLabel.inbox)
        await mailbox.queueDrop([wrong], on: .account("a", "target"))?.value
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").isEmpty })
        #expect(try await labels("m1", account: "a", in: cache) == [SystemLabel.inbox, "source", "tag"])
    }

    @Test func snoozedMailMustBeUnsnoozedBeforeMovingButCanBeTagged() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let item = drag(account: "a", message: "m1", source: MailboxModel.snoozedID)
        #expect(mailbox.queueDrop([item], on: .account("a", "target")) == nil)
        #expect(mailbox.queueDrop([item], on: .combined(SystemLabel.allMail)) == nil)
        #expect(mailbox.notice != nil)
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").isEmpty })
        let task = try #require(mailbox.queueDrop([item], on: .account("a", "target"), copy: true))
        await task.value
        #expect(try await labels("m1", account: "a", in: cache) == [SystemLabel.inbox, "source", "tag", "target"])
    }

    @Test func searchCannotMoveSnoozedMailAndAnInvalidAccountBatchChangesNothing() async throws {
        let (mailbox, cache) = try await fixture(twoAccounts: true)
        defer { Task { await mailbox.stop() } }
        let valid = drag(account: "a", message: "m1", source: SystemLabel.inbox)
        let invalid = ConversationDragItem(MailLink(accountID: "b", threadID: "other", messageID: "m1"),
                                           sourceLabelID: SystemLabel.inbox)
        await mailbox.queueDrop([valid, invalid], on: .combined(SystemLabel.trash))?.value
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").isEmpty })
        #expect(try await cache.read { try $0.pendingActions(accountID: "b").isEmpty })

        try await cache.write { tx in
            try tx.holdMessageSnooze(.init(accountID: "a", messageID: "m1", threadID: "t",
                                          wakeAt: .now.addingTimeInterval(3600), createdAt: .now))
        }
        let searchItem = ConversationDragItem(MailLink(accountID: "a", threadID: "t", messageID: "m1"))
        await mailbox.queueDrop([searchItem], on: .account("a", "target"))?.value
        #expect(try await cache.read { try $0.pendingActions(accountID: "a").isEmpty })
        #expect(mailbox.notice?.message.contains("snooze") == true)
    }

    private func drag(account: String, message: String, source: String) -> ConversationDragItem {
        ConversationDragItem(MailLink(accountID: account, threadID: "t", messageID: message), sourceLabelID: source)
    }

    private func labels(_ message: String, account: String, in cache: MailCache) async throws -> Set<String> {
        try await cache.read { try $0.currentLabels(threadID: "t", accountID: account)[message] ?? [] }
    }

    private func fixture(twoAccounts: Bool = false) async throws -> (MailboxModel, MailCache) {
        let cache = try MailCache.inMemory()
        let accountIDs = twoAccounts ? ["a", "b"] : ["a"]
        try await cache.write { tx in
            for accountID in accountIDs {
                try tx.replaceLabels(["source", "tag", "target"].map {
                    LabelRecord(accountID: accountID, id: $0, name: $0.capitalized, isSystem: false)
                }, accountID: accountID)
                _ = try tx.upsertMessages(["m1", "m2"].map { id in
                    CacheTransaction.MessageUpdate(record: MessageRecord(accountID: accountID, id: id, threadID: "t",
                        historyID: 1, date: .now, snippet: "", sender: "sender@example.invalid", recipients: "me@example.invalid",
                        cc: nil, subject: "Notes", sizeEstimate: 10), labelIDs: [SystemLabel.inbox, "source", "tag"])
                })
                try tx.rebuildThreads(["t"], accountID: accountID)
            }
        }
        func account(_ id: String) -> AccountRecord {
            AccountRecord(id: id, email: id + "@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        }
        let defaults = try #require(UserDefaults(suiteName: "tern.drop.tests." + UUID().uuidString))
        let mailbox = MailboxModel(account: account("a"), cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory, syncEnabled: false,
            listPreferences: MessageListPreferences(defaults: defaults))
        if twoAccounts { await mailbox.addAccount(account("b"), gmail: AuditGmail(), syncEnabled: false) }
        await mailbox.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mailbox.accounts.contains(where: { $0.labels.count != 3 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(mailbox.accounts.allSatisfy { $0.labels.count == 3 })
        return (mailbox, cache)
    }
}
