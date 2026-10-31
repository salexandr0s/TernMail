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
        // Gmail names system labels after their IDs.
        let system = [SystemLabel.important, "CATEGORY_PURCHASES"].map { LabelRecord(accountID: "a", id: $0, name: $0, isSystem: true) }
        try await cache.write { tx in
            try tx.replaceLabels([hidden] + system, accountID: "a")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mailbox.labels.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mailbox.isVisibleInSidebar(hidden) == false)
        func title(_ id: String) -> String? { mailbox.mailboxSwitchOptions.first { $0.mailbox == .account("a", id) }?.title }
        #expect(title("hidden") == "Hidden")
        #expect(title(SystemLabel.important) == "Important")
        #expect(title("CATEGORY_PURCHASES") == "Purchases")
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

    @Test func projectedRowsRefreshMetadataAndSendingAliasesWithoutChangingMessageIDs() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        mailbox.listPreferences.conversations = false
        mailbox.listPreferences.filters = [.addressedToMe]
        #expect(mailbox.listItems.count == 2)

        let entry = try #require(mailbox.listEntries.first)
        var message = entry.message
        message.recipients = "alias@example.com"
        message.subject = "Updated subject"
        mailbox.listEntries = [.init(message: message, labels: entry.labels)]
        #expect(mailbox.listItems.isEmpty)
        mailbox.listOwnAddresses = ["a": ["alias@example.com"]]
        #expect(mailbox.listItems.first?.thread.subject == "Updated subject")

        let file = AttachmentRecord(accountID: "a", messageID: message.id, partID: "file", attachmentID: "remote",
            filename: "notes.pdf", mimeType: "application/pdf", size: 20, isInline: false)
        mailbox.listEntries = [.init(message: message, labels: [SystemLabel.inbox, SystemLabel.unread], attachments: [file])]
        #expect(mailbox.listItems.first?.thread.isUnread == true)
        #expect(mailbox.listItems.first?.thread.isStarred == false)
        #expect(mailbox.listItems.first?.attachments == [file])

        mailbox.listPreferences.filters = [.starred]
        #expect(mailbox.listItems.isEmpty)
        mailbox.listPreferences.filters = []
        #expect(mailbox.listItems.count == 1)
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

    @Test func deleteKeyFollowsTheSettingsChoice() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let key = ThreadKey(accountID: "a", threadID: "t")
        mailbox.listPreferences.nextSelection = .none
        mailbox.selectedThreadIDs = [key]
        await mailbox.performDeleteKeyAction(.archive)?.value
        var pending = try await cache.read { try $0.pendingActions(accountID: "a") }
        #expect(pending.map(\.kind) == [.modifyThreads])
        #expect(pending.first?.removeLabelIDs == [SystemLabel.inbox])
        mailbox.selectedThreadIDs = [key]
        await mailbox.performDeleteKeyAction(.trash)?.value
        pending = try await cache.read { try $0.pendingActions(accountID: "a") }
        #expect(pending.map(\.kind) == [.modifyThreads, .trashThreads])
        // Nothing selected: the key does nothing rather than acting on stale targets.
        mailbox.selectedThreadIDs = []
        #expect(mailbox.performDeleteKeyAction(.trash) == nil)
    }

    @Test func rowSummaryLeadsWithUnreadAndEndsWithStarred() {
        let summary = MessageListRow.accessibilitySummary(unread: true, sender: "Sender", subject: "Planning",
                                                          date: "Oct 30", messageCount: 3, starred: true)
        #expect(summary == "Unread, Sender, Planning, Oct 30, 3 messages, starred")
        #expect(MessageListRow.accessibilitySummary(unread: false, sender: "Sender", subject: "", date: "Oct 30",
                                                    messageCount: 1, starred: false) == "Sender, No Subject, Oct 30")
    }

    @Test func searchHighlightsMatchWholeWordsAndStartLongPreviewsNearTheMatch() {
        func bold(_ string: AttributedString) -> [String] {
            string.runs.compactMap { run in
                run.inlinePresentationIntent == .stronglyEmphasized ? String(string[run.range].characters) : nil
            }
        }
        let highlights = SearchHighlights(SearchQuery("cafe -rain subject:plans \"trail map\" sat"))
        // Case and accents don't matter. Words match whole, except the last one typed.
        #expect(bold(highlights.subject("Café plans for Saturday")) == ["Café", "plans", "Sat"])
        #expect(bold(highlights.preview("Café plans, then the Trail Map. Rain or not, cafes open")) == ["Café", "Trail Map"])

        let preview = highlights.preview("Thanks for the photos from last weekend, they look great. The trail map is attached.")
        #expect(String(preview.characters) == "…great. The trail map is attached.")
        #expect(bold(preview) == ["trail map"])
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

    @Test func addingAnAccountPreservesTheSelectedExistingAccountRows() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let row = try #require(mailbox.listItems.first)
        mailbox.selectListRows([row.id])
        let second = AccountRecord(id: "b", email: "second@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(second, gmail: AuditGmail(), syncEnabled: false)
        #expect(mailbox.selectedListRowIDs == [row.id])
        #expect(mailbox.listItems.map(\.id) == [row.id])
    }

    @Test func selectionReusesPreparedRowsWithoutComparingOrRebuildingThePage() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let rows = mailbox.listItems
        let count = mailbox.listProjection.preparationCount
        for _ in 0..<100 {
            mailbox.selectListRows(Set(rows.map(\.id)))
            _ = mailbox.listItems
            mailbox.selectListRows([])
            _ = mailbox.listItems
        }
        #expect(mailbox.listProjection.preparationCount == count)
        #expect(mailbox.listItems.first?.sender?.address == "sender@example.com")
    }

    @Test func databaseChangesPublishThreadsAndMessagesTogetherWithoutAListView() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        // No SwiftUI view or second message observation is mounted in this test.
        try await cache.write { tx in
            let removed = try tx.deleteMessages(ids: ["m1"], accountID: "a")
            try tx.rebuildThreads(removed, accountID: "a")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mailbox.threads.first?.messageCount != 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(mailbox.threads.first?.messageCount == 1)
        #expect(mailbox.listEntries.map(\.message.id) == ["m2"])
        #expect(mailbox.listItems.first?.messages.map(\.message.id) == ["m2"])
        #expect(mailbox.isListPresentationReady)
    }

    @Test func returningToAnObservedMailboxReusesItsCompletePage() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        let inbox = mailbox.listItems
        mailbox.selectedMailbox = .account("a", SystemLabel.starred)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !mailbox.isListPresentationReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(mailbox.listItems.first?.messages.map(\.message.id) == ["m1"])
        mailbox.selectedMailbox = .account("a", SystemLabel.inbox)
        // No yield: returning publishes the retained transaction and rows now.
        #expect(mailbox.isListPresentationReady)
        #expect(mailbox.listItems == inbox)
    }

    @Test func localActionsInvalidateRetainedPagesBeforeReturningToThem() async throws {
        let (mailbox, _) = try await fixture()
        defer { Task { await mailbox.stop() } }
        mailbox.selectedMailbox = .account("a", SystemLabel.starred)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !mailbox.isListPresentationReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        mailbox.selectedMailbox = .account("a", SystemLabel.inbox)
        let key = try #require(mailbox.threads.first?.key)
        await mailbox.perform(.unstar, on: [key])?.value
        mailbox.selectedMailbox = .account("a", SystemLabel.starred)
        // The old starred row must never be replayed while a new read is pending.
        #expect(mailbox.listItems.isEmpty)
        let finish = ContinuousClock.now.advanced(by: .seconds(2))
        while !mailbox.isListPresentationReady, ContinuousClock.now < finish {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(mailbox.isListPresentationReady)
        #expect(mailbox.listItems.isEmpty)
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
        #expect(mailbox.isListPresentationReady)
        #expect(mailbox.listEntries.count == 2)
        return (mailbox, cache)
    }
}
