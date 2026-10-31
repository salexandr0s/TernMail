import Foundation
import MailStore
import MessageContent
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct MessageListTests {
    @Test func openingAMessageWindowUsesTheClickedRowRatherThanTheSelection() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        mailbox.listPreferences.conversations = false
        let selected = try #require(mailbox.listItems.first { $0.id.messageID == "m1" })
        let clicked = try #require(mailbox.listItems.first { $0.id.messageID == "m2" })
        mailbox.selectListRows([selected.id])
        mailbox.requestConversationWindow(for: clicked.id)
        #expect(mailbox.conversationWindowRequest == MailLink(accountID: "a", threadID: "t", messageID: "m2"))
        #expect(mailbox.selectedMessageRows == [selected.id])

        let otherConversation = MailListRowID(accountID: "b", threadID: "other", messageID: "m3")
        mailbox.requestConversationWindow(for: otherConversation)
        #expect(mailbox.conversationWindowRequest == MailLink(accountID: "b", threadID: "other", messageID: "m3"))
        mailbox.listPreferences.conversations = true
        mailbox.requestConversationWindow(for: clicked.id)
        #expect(mailbox.conversationWindowRequest == MailLink(accountID: "a", threadID: "t"))
    }

    @Test func mailboxSwitcherIncludesSystemAndHiddenLabels() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let hidden = LabelRecord(accountID: "a", id: "hidden", name: "Hidden", isSystem: false, labelListVisibility: "labelHide")
        try await cache.write { tx in
            try tx.replaceLabels([hidden, .init(accountID: "a", id: SystemLabel.important, name: "Important", isSystem: true)], accountID: "a")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mailbox.labels.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mailbox.isVisibleInSidebar(hidden) == false)
        #expect(mailbox.mailboxSwitchOptions.contains { $0.mailbox == .account("a", "hidden") })
        #expect(mailbox.mailboxSwitchOptions.contains { $0.mailbox == .account("a", SystemLabel.important) })
    }

    @Test func messageSnoozeAndItsDatePickerKeepExactTargetsAndCancelClearsTheSnapshot() async throws {
        let (mailbox, cache) = try await fixture(withStore: true)
        defer { Task { await mailbox.stop() } }
        mailbox.listPreferences.conversations = false
        let selected = try #require(mailbox.listItems.first(where: { $0.id.messageID == "m1" }))
        mailbox.selectListRows([selected.id])
        mailbox.showSnoozeDate(forRows: [selected.id])
        #expect(mailbox.snoozeRowTargets == [selected.id])
        mailbox.snoozeDateTargets = nil
        #expect(mailbox.snoozeRowTargets == nil)
        await mailbox.snoozeRows([selected.id], until: .now.addingTimeInterval(3600))?.value
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"]?.contains(SystemLabel.inbox) == false)
        #expect(labels["m2"]?.contains(SystemLabel.inbox) == true)
        var snoozed = cache.messageListEntries(threadsByAccount: ["a": ["t"]], snoozedOnly: true).makeAsyncIterator()
        #expect(try await snoozed.next()?.map(\.message.id) == ["m1"])
    }

    @Test func messageModeActionsAndLabelPickersRetainOnlyTheSelectedMessage() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        mailbox.listPreferences.conversations = false
        let selected = try #require(mailbox.listItems.first(where: { $0.id.messageID == "m1" }))
        mailbox.selectListRows([selected.id])
        #expect(mailbox.selectedThreadIDs == [selected.id.threadKey])
        #expect(mailbox.selectedActionTargets.first?.target == .messages(["m1"]))
        mailbox.showEditLabels()
        #expect(mailbox.labelEdit?.messageIDs == ["m1"])
        mailbox.showMoveTo()
        #expect(mailbox.moveMessageTargets == ["m1"])
        await mailbox.perform(.archive)?.value
        let labels = try await cache.read { try $0.currentLabels(threadID: "t", accountID: "a") }
        #expect(labels["m1"]?.contains(SystemLabel.inbox) == false)
        #expect(labels["m2"]?.contains(SystemLabel.inbox) == true)
    }

    @Test func quickFiltersAndCategoryTabsApplyToEachMessageWithoutRemovingItsSibling() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        mailbox.accountPresentation["a"] = .init(accountID: "a", inboxCategories: [.promotions])
        mailbox.listPreferences.conversations = false
        #expect(mailbox.listItems.map(\.id.messageID) == ["m2"])
        mailbox.listPreferences.filters = [.unread, .addressedToMe]
        #expect(mailbox.listItems.map(\.id.messageID) == ["m2"])
        mailbox.listPreferences.filters = [.starred]
        #expect(mailbox.listItems.isEmpty)
        mailbox.listPreferences.filters = []
        mailbox.listPreferences.conversations = true
        #expect(mailbox.listItems.count == 1)
        #expect(mailbox.listItems.first?.messages.map(\.message.id) == ["m2"])
    }

    @Test(arguments: [true, false])
    func customMailboxShowsOnlyMessagesCarryingItsLabel(conversations: Bool) async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let action = LabelRecord(accountID: "a", id: "action", name: "01 Action", isSystem: false)
        let waiting = LabelRecord(accountID: "a", id: "waiting", name: "02 Waiting", isSystem: false)
        try await cache.write { tx in
            try tx.replaceLabels([action, waiting], accountID: "a")
            _ = try tx.applyLabelChange(messageID: "m1", added: [action.id], removed: [], historyID: 2, accountID: "a")
            _ = try tx.applyLabelChange(messageID: "m2", added: [waiting.id], removed: [], historyID: 2, accountID: "a")
            try tx.rebuildThreads(["t"], accountID: "a")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mailbox.labels.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(mailbox.labels.contains { $0.id == action.id })
        var iterator = cache.messageListEntries(threadsByAccount: ["a": ["t"]]).makeAsyncIterator()
        mailbox.listEntries = try #require(try await iterator.next())
        mailbox.listPreferences.conversations = conversations

        for (label, messageID) in [(action, "m1"), (waiting, "m2")] {
            mailbox.selectedMailbox = .account("a", label.id)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while mailbox.threads.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try #require(!mailbox.threads.isEmpty)
            #expect(mailbox.listItems.flatMap(\.messages).map(\.message.id) == [messageID])
            #expect(mailbox.listItems.allSatisfy { $0.labels.contains(label.id) })
        }
    }

    @Test func selectedCustomLabelRemainsVisibleBeforeOtherLabels() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let source = try #require(mailbox.listItems.first)
        let available = [
            LabelRecord(accountID: "a", id: "action", name: "Z Action", isSystem: false),
            LabelRecord(accountID: "a", id: "accounts", name: "Accounts & Security", isSystem: false),
            LabelRecord(accountID: "a", id: "finance", name: "Finance", isSystem: false),
            LabelRecord(accountID: "a", id: "absent", name: "Absent", isSystem: false)
        ] + [SystemLabel.inbox, SystemLabel.unread, SystemLabel.starred, SystemLabel.important, SystemLabel.allMail].map {
            LabelRecord(accountID: "a", id: $0, name: $0, isSystem: true)
        }
        let entry = MessageListEntry(message: try #require(source.messages.first).message,
            labels: Set(available.filter { $0.id != "absent" }.map(\.id)))
        let item = MessageListItem(id: source.id, thread: source.thread, messages: [entry])
        let displayed = item.displayedLabels(from: available, mailboxID: "action").map(\.id)
        #expect(Array(displayed.prefix(2)) == ["action", "accounts"])
        #expect(displayed == ["action", "accounts", "finance", SystemLabel.inbox])
        #expect(item.displayedLabels(from: available, mailboxID: SystemLabel.inbox).map(\.id) == ["accounts", "finance", "action"])
    }

    @Test func selectionPreferenceAndMixedTargetsNeverWidenMessageAuthority() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        mailbox.listPreferences.conversations = false
        let rows = mailbox.listItems.map(\.id)
        mailbox.listPreferences.nextSelection = .none
        mailbox.selectListRows([rows[0]])
        mailbox.selectRow(after: [rows[0]])
        #expect(mailbox.selectedMessageRows.isEmpty)
        let mixed = Set([rows[0], MailListRowID(accountID: "a", threadID: "t")])
        #expect(mailbox.actionTargets(forRows: mixed).isEmpty)
    }

    @Test func profilePresentationFiltersOwnersAndFavoritesKeepExplicitScopes() async throws {
        let (mailbox, _) = try await fixture()
        let second = AccountRecord(id: "b", email: "second@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(second, gmail: AuditGmail(), syncEnabled: false)
        mailbox.applyAccountPresentation(preferences: [.init(accountID: "a", nickname: "Work"), .init(accountID: "b")], visibleAccountIDs: ["a"])
        #expect(mailbox.presentedAccounts.map(\.account.id) == ["a"])
        #expect(mailbox.accountTitle(mailbox.account) == "Work")
        #expect(mailbox.favoriteMailboxID(.mailbox(labelID: SystemLabel.inbox, scope: .accounts(["b"]))) == nil)
        #expect(mailbox.favoriteMailboxID(.mailbox(labelID: SystemLabel.inbox, scope: .accounts(["a"]))) == .account("a", SystemLabel.inbox))
        mailbox.selectedMailbox = .combined(SystemLabel.starred)
        mailbox.applyAccountPresentation(preferences: [], visibleAccountIDs: ["b"])
        #expect(mailbox.selectedMailbox == .account("b", SystemLabel.starred))
        #expect(mailbox.favoriteMailboxID(.mailbox(labelID: SystemLabel.inbox, scope: .allAccounts)) == .account("b", SystemLabel.inbox))
        await mailbox.stop()
    }

    private func fixture(withStore: Bool = false) async throws -> (MailboxModel, MailCache) {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            let first = MessageRecord(accountID: "a", id: "m1", threadID: "t", historyID: 1, date: Date(timeIntervalSince1970: 2),
                snippet: "", sender: "Sender <sender@example.com>", recipients: "me@example.com", cc: nil, subject: "Planning", sizeEstimate: 1)
            var second = first
            second.id = "m2"; second.date = Date(timeIntervalSince1970: 1)
            try tx.upsertMessages([
                .init(record: first, labelIDs: [SystemLabel.inbox, SystemLabel.starred, "CATEGORY_PROMOTIONS"]),
                .init(record: second, labelIDs: [SystemLabel.inbox, SystemLabel.unread])
            ])
            try tx.rebuildThreads(["t"], accountID: "a")
        }
        let defaults = try #require(UserDefaults(suiteName: "tern.message-list.tests." + UUID().uuidString))
        let preferences = MessageListPreferences(defaults: defaults)
        let account = AccountRecord(id: "a", email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        let store = withStore ? try AccountStore.inMemory() : nil
        try await store?.save(account)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: FileManager.default.temporaryDirectory,
                                   snoozeStore: store, syncEnabled: false, listPreferences: preferences)
        await mailbox.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mailbox.threads.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!mailbox.threads.isEmpty)
        var iterator = cache.messageListEntries(threadsByAccount: ["a": ["t"]]).makeAsyncIterator()
        mailbox.listEntries = try #require(try await iterator.next())
        return (mailbox, cache)
    }
}
