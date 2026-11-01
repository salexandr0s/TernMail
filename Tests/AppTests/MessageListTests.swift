import AppKit
import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine
import SwiftUI
import Synchronization
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct MessageListTests {
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

    #if DEBUG || TERN_PERFORMANCE
    @Test func nativeSelectionUpdatesRealizedRowsWithoutRebuildingTheListContent() async throws {
        let (mailbox, cache) = try await fixture()
        defer { Task { await mailbox.stop() } }
        try await cache.write { tx in
            let other = MessageRecord(accountID: "b", id: "m1", threadID: "t", historyID: 1,
                date: Date(timeIntervalSince1970: 3), snippet: "", sender: "Other <other@example.com>",
                recipients: "second@example.com", cc: nil, subject: "Other account", sizeEstimate: 1)
            try tx.upsertMessages([.init(record: other, labelIDs: [SystemLabel.inbox])])
            try tx.rebuildThreads(["t"], accountID: "b")
            for index in 0..<40 {
                let message = MessageRecord(accountID: "a", id: "filler-\(index)", threadID: "filler-\(index)", historyID: 1,
                    date: Date(timeIntervalSince1970: Double(-index)), snippet: "", sender: "Sender <sender@example.com>",
                    recipients: "me@example.com", cc: nil, subject: "Scroll row \(index)", sizeEstimate: 1)
                try tx.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox])])
                try tx.rebuildThreads([message.threadID], accountID: "a")
            }
        }
        let otherAccount = AccountRecord(id: "b", email: "second@example.com", displayName: nil, grantedScopes: [], addedAt: .now)
        await mailbox.addAccount(otherAccount, gmail: AuditGmail(), syncEnabled: false)
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        try await awaitListState("combined conversation page", details: {
            "ready=\(mailbox.isListPresentationReady), rows=\(mailbox.listItems.count)"
        }) { mailbox.isListPresentationReady && mailbox.listItems.count == 42 }
        let conversationObservation = selectionObservationCounts(mailbox, target: .init(accountID: "a", threadID: "t"))

        var contentBuilds = 0
        var listBodyBuilds = 0
        var dragBodyBuilds = 0
        var rendered: [MailListRowID: MessageListRow.RenderState] = [:]
        var visualBodyBuilds: [MailListRowID: Int] = [:]
        var selectionObserverBuilds: [MailListRowID: Int] = [:]
        ThreadListView.onRowContentBuild = { owner, _ in if owner === mailbox { contentBuilds += 1 } }
        ThreadListView.onBodyBuild = { owner, phase in
            guard owner === mailbox else { return }
            switch phase {
            case .list: listBodyBuilds += 1
            case .dragSelection: dragBodyBuilds += 1
            }
        }
        MessageListRow.onBodyEvaluation = { owner, id, state in
            guard owner === mailbox else { return }
            rendered[id] = state
            visualBodyBuilds[id, default: 0] += 1
        }
        MessageListRow.onSelectionObserverEvaluation = { owner, id in
            if owner === mailbox { selectionObserverBuilds[id, default: 0] += 1 }
        }
        defer {
            ThreadListView.onRowContentBuild = nil
            ThreadListView.onBodyBuild = nil
            MessageListRow.onBodyEvaluation = nil
            MessageListRow.onSelectionObserverEvaluation = nil
        }
        // The isolated List has no workspace minimum size. Give its hosting
        // controller a real viewport instead of its tiny intrinsic fitting size.
        let viewDefaultsName = "tern.message-list.row-views." + UUID().uuidString
        let viewDefaults = try #require(UserDefaults(suiteName: viewDefaultsName))
        defer { viewDefaults.removePersistentDomain(forName: viewDefaultsName) }
        let controller = NSHostingController(rootView: ThreadListView(mailbox: mailbox)
            .frame(width: 520, height: 540).environment(AppModel()).defaultAppStorage(viewDefaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close() }
        try await awaitListState("native conversation table", details: {
            "tableRows=\(self.listTables(in: controller.view).map(\.numberOfRows))"
        }) { self.listTables(in: controller.view).first?.numberOfRows == 42 }
        let table = try #require(listTables(in: controller.view).first)
        let scroll = try #require(table.enclosingScrollView)
        try await awaitListState("fixed mailbox fixture viewport and initial realized rows", details: {
            "viewport=\(table.visibleRect), clip=\(scroll.contentView.bounds), host=\(controller.view.bounds), "
                + "realized=\((0..<2).map { table.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil })"
        }) {
            table.window === window && table.visibleRect.width >= 400 && table.visibleRect.height >= 400
                && (0..<2).allSatisfy {
                    table.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil
                        && table.rect(ofRow: $0).intersects(table.visibleRect)
                }
        }

        func indexes(for ids: Set<MailListRowID>) -> IndexSet {
            IndexSet(mailbox.listItems.indices.filter { ids.contains(mailbox.listItems[$0].id) })
        }
        func realizedSentinelCounts(_ id: MailListRowID, sourceLocation: SourceLocation = #_sourceLocation) async throws -> (visual: Int, observer: Int) {
            try await awaitListState("unchanged visible row sentinel", details: {
                "id=\(id), visual=\(visualBodyBuilds[id, default: 0]), observer=\(selectionObserverBuilds[id, default: 0]), body=\(String(describing: rendered[id]))"
            }, sourceLocation: sourceLocation) {
                guard let index = mailbox.listItems.firstIndex(where: { $0.id == id }) else { return false }
                return visualBodyBuilds[id, default: 0] > 0 && rendered[id]?.selected == false
                    && table.view(atColumn: 0, row: index, makeIfNecessary: false) != nil
                    && table.rect(ofRow: index).intersects(table.visibleRect)
            }
            return (visualBodyBuilds[id, default: 0], selectionObserverBuilds[id, default: 0])
        }
        func expectSelection(_ ids: Set<MailListRowID>, native: Bool, visibleRows: [MailListRowID],
                             sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let expected = indexes(for: ids)
            if native { table.selectRowIndexes(expected, byExtendingSelection: false) }
            else { mailbox.selectListRows(ids) }
            try await awaitListState(native ? "native selection publication" : "model selection publication", details: {
                let rows = visibleRows.map { id in
                    let index = mailbox.listItems.firstIndex { $0.id == id }
                    let view = index.flatMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) }
                    let rect = index.map { table.rect(ofRow: $0) }
                    return "\(id): body=\(String(describing: rendered[id])), nativeView=\(view != nil), rect=\(String(describing: rect))"
                }.joined(separator: "; ")
                return "conversations=\(mailbox.listPreferences.conversations), expected=\(Array(expected)), "
                    + "native=\(Array(table.selectedRowIndexes)), model=\(mailbox.selectedListRowIDs.sorted()), "
                    + "viewport=\(table.visibleRect), columns=\(table.numberOfColumns), window=\(table.window === window); \(rows)"
            }, sourceLocation: sourceLocation) {
                mailbox.selectedListRowIDs == ids && table.selectedRowIndexes == expected
                    && visibleRows.allSatisfy { id in
                        guard let row = mailbox.listItems.firstIndex(where: { $0.id == id }) else { return false }
                        return rendered[id]?.selected == ids.contains(id)
                            && table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil
                            && table.rect(ofRow: row).intersects(table.visibleRect)
                    }
            }
            for id in visibleRows {
                let row = try #require(mailbox.listItems.firstIndex { $0.id == id })
                try #require(table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil)
                #expect(table.rect(ofRow: row).intersects(table.visibleRect))
            }
        }

        func expectRapidSelection(_ ids: [MailListRowID], sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try #require(ids.count > 1, sourceLocation: sourceLocation)
            let inputs = (0..<24).map { ids[($0 + 1) % ids.count] }
            let finalTarget = Set([try #require(inputs.last, sourceLocation: sourceLocation)])
            try #require(mailbox.selectedListRowIDs != finalTarget && table.selectedRowIndexes != indexes(for: finalTarget),
                "The burst must finish on a different row from the settled native selection", sourceLocation: sourceLocation)
            let buildsBeforeBurst = contentBuilds
            let anchorBeforeBurst = scroll.contentView.bounds.origin
            var journal: [String] = []
            var requested = Set<MailListRowID>()
            func record(_ phase: String) {
                journal.append("\(phase): requested=\(requested.sorted()), model=\(mailbox.selectedListRowIDs.sorted()), native=\(Array(table.selectedRowIndexes))")
            }
            // Inputs arrive faster than AppKit can publish selection back.
            for (index, id) in inputs.enumerated() {
                requested = [id]
                mailbox.selectListRows(requested)
                record("input \(index)")
                try #require(mailbox.selectedListRowIDs == requested, "\(journal.joined(separator: "\n"))", sourceLocation: sourceLocation)
            }
            let expected = indexes(for: requested)
            try await awaitListState("rapid selection final native and row publication", details: {
                record("awaiting final publication")
                return journal.joined(separator: "\n")
            }, sourceLocation: sourceLocation) {
                mailbox.selectedListRowIDs == requested && table.selectedRowIndexes == expected
                    && ids.allSatisfy { id in
                        guard let row = mailbox.listItems.firstIndex(where: { $0.id == id }) else { return false }
                        return rendered[id]?.selected == requested.contains(id)
                            && table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil
                            && table.rect(ofRow: row).intersects(table.visibleRect)
                    }
            }
            // Do not reapply the requested selection: a delayed native writeback
            // must leave the final target intact as queued work is processed.
            for turn in 0..<8 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { continuation.resume() }
                }
                record("main queue turn \(turn)")
                try #require(mailbox.selectedListRowIDs == requested && table.selectedRowIndexes == expected,
                    "\(journal.joined(separator: "\n"))", sourceLocation: sourceLocation)
            }
            #expect(contentBuilds == buildsBeforeBurst, "Rapid selection must not rebuild ForEach", sourceLocation: sourceLocation)
            #expect(listTables(in: controller.view).first === table, sourceLocation: sourceLocation)
            #expect(table.enclosingScrollView === scroll, sourceLocation: sourceLocation)
            #expect(abs(scroll.contentView.bounds.origin.y - anchorBeforeBurst.y) < 1, sourceLocation: sourceLocation)
        }

        let conversationA = MailListRowID(accountID: "a", threadID: "t")
        let conversationB = MailListRowID(accountID: "b", threadID: "t")
        let conversations = [conversationA, conversationB]
        try await expectSelection([conversationA], native: true, visibleRows: conversations)
        try await expectSelection(Set(conversations), native: true, visibleRows: conversations)
        try await expectSelection([conversationB], native: false, visibleRows: conversations)
        #expect(mailbox.selectedThreadIDs == [conversationB.threadKey])
        let buildsBeforeConversationSwitching = contentBuilds
        let conversationBodies = (listBodyBuilds, dragBodyBuilds)
        let conversationSentinel = MailListRowID(accountID: "a", threadID: "filler-0")
        let conversationSentinelBefore = try await realizedSentinelCounts(conversationSentinel)
        for index in 0..<12 {
            try await expectSelection([conversations[index % conversations.count]],
                native: index.isMultiple(of: 3), visibleRows: conversations)
        }
        #expect(contentBuilds == buildsBeforeConversationSwitching,
            "Conversation selection must not rebuild ForEach; root delta=\(listBodyBuilds - conversationBodies.0), drag delta=\(dragBodyBuilds - conversationBodies.1), observation=\(conversationObservation)")
        let conversationSentinelAfter = try await realizedSentinelCounts(conversationSentinel)
        #expect(conversationSentinelAfter.observer > conversationSentinelBefore.observer)
        #expect(conversationSentinelAfter.visual == conversationSentinelBefore.visual,
            "Conversation selection must preserve unchanged visible row content")
        try await expectRapidSelection(conversations)

        mailbox.listPreferences.conversations = false
        try await awaitListState("message mode table and cleared selection", details: {
            "rows=\(table.numberOfRows), selected=\(mailbox.selectedListRowIDs.sorted())"
        }) { table.numberOfRows == 43 && mailbox.selectedListRowIDs.isEmpty }
        let first = MailListRowID(accountID: "a", threadID: "t", messageID: "m1")
        let sibling = MailListRowID(accountID: "a", threadID: "t", messageID: "m2")
        let other = MailListRowID(accountID: "b", threadID: "t", messageID: "m1")
        let messages = [first, sibling, other]
        let messageObservation = selectionObservationCounts(mailbox, target: first)
        // Warm the row/focus graph before measuring selection-only updates.
        for id in messages { try await expectSelection([id], native: true, visibleRows: messages) }
        let buildsBeforeSwitching = contentBuilds
        let messageBodies = (listBodyBuilds, dragBodyBuilds)
        let messageSentinel = MailListRowID(accountID: "a", threadID: "filler-0", messageID: "filler-0")
        let messageSentinelBefore = try await realizedSentinelCounts(messageSentinel)
        for index in 0..<24 {
            try await expectSelection([messages[index % messages.count]], native: index.isMultiple(of: 2), visibleRows: messages)
        }
        #expect(contentBuilds == buildsBeforeSwitching,
            "Message selection must not rebuild ForEach; root delta=\(listBodyBuilds - messageBodies.0), drag delta=\(dragBodyBuilds - messageBodies.1), observation=\(messageObservation)")
        let messageSentinelAfter = try await realizedSentinelCounts(messageSentinel)
        #expect(messageSentinelAfter.observer > messageSentinelBefore.observer)
        #expect(messageSentinelAfter.visual == messageSentinelBefore.visual,
            "Message selection must preserve unchanged visible row content")
        try await expectRapidSelection(messages)
        #expect(listTables(in: controller.view).first === table)
        #expect(table.enclosingScrollView === scroll)
        try await expectSelection(Set(messages), native: true, visibleRows: messages)
        #expect(mailbox.selectedMessageRows == Set(messages))
        #expect(mailbox.selectedActionTargets.first { $0.accountID == "a" }?.target == .messages(["m1", "m2"]))
        #expect(mailbox.selectedActionTargets.first { $0.accountID == "b" }?.target == .messages(["m1"]))

        // Both selected rows remain inside a scrolled viewport; switching must
        // keep its native table and current scroll anchor.
        table.scrollRowToVisible(12)
        try await awaitListState("scrolled native viewport", details: {
            "clip=\(scroll.contentView.bounds), document=\(table.bounds)"
        }) { scroll.contentView.bounds.minY > 0 }
        let visible = table.rows(in: table.visibleRect)
        try #require(visible.length >= 4 && visible.location + 2 < mailbox.listItems.count)
        let lowerRows = [visible.location + 1, visible.location + 2].map { mailbox.listItems[$0].id }
        try await expectSelection([lowerRows[0]], native: true, visibleRows: lowerRows)
        let anchor = scroll.contentView.bounds.origin
        try await expectSelection([lowerRows[1]], native: false, visibleRows: lowerRows)
        #expect(abs(scroll.contentView.bounds.origin.y - anchor.y) < 1)
        #expect(listTables(in: controller.view).first === table)

        table.scrollRowToVisible(0)
        try await expectSelection([sibling], native: true, visibleRows: messages)
        try #require(rendered[sibling]?.unread == true && rendered[sibling]?.starred == false)
        await mailbox.performListAction(.markRead, rows: [sibling])?.value
        await mailbox.performListAction(.star, rows: [sibling])?.value
        // This hook is inside the actual realized row body. It records the
        // values used by production content, not a model-only projection.
        try await awaitListState("read and star publication in realized message row", details: {
            "body=\(String(describing: rendered[sibling]))"
        }) { rendered[sibling]?.unread == false && rendered[sibling]?.starred == true }
        let siblingIndex = try #require(mailbox.listItems.firstIndex { $0.id == sibling })
        #expect(table.view(atColumn: 0, row: siblingIndex, makeIfNecessary: false) != nil)
        #expect(table.rect(ofRow: siblingIndex).intersects(table.visibleRect))
        #expect(table.selectedRowIndexes == indexes(for: [sibling]))
        #expect(listTables(in: controller.view).first === table)

        // The visual leaf still observes settings even when its immutable row
        // and selection inputs remain unchanged.
        viewDefaults.set(1.25, forKey: ReadingPreferences.textScaleKey)
        try await awaitListState("text scale reaches the unselected visual row", details: {
            "body=\(String(describing: rendered[first]))"
        }) { rendered[first]?.textScale == 1.25 && rendered[first]?.selected == false }
        mailbox.listPreferences.density = .compact
        try await awaitListState("density reaches the unselected visual row", details: {
            "body=\(String(describing: rendered[first]))"
        }) { rendered[first]?.compact == true && rendered[first]?.selected == false }
        let firstIndex = try #require(mailbox.listItems.firstIndex { $0.id == first })
        #expect(table.view(atColumn: 0, row: firstIndex, makeIfNecessary: false) != nil)
        #expect(table.rect(ofRow: firstIndex).intersects(table.visibleRect))
        #expect(table.selectedRowIndexes == indexes(for: [sibling]))
    }

    /// Exercises production mail columns and reader lifecycle in a background window.
    @Test func productionMailColumnsSelectBeforeBodyDeliveryAndPreserveSelectionAfterLateCompletion() async throws {
        let gate = SelectionBodyGate()
        let gmail = AuditGmail(performanceFixtureCount: 200, beforeFullThread: { id in
            try await gate.wait(id, priority: GmailRequestBudget.priority)
        })
        let first = MailListRowID(accountID: "ui-audit", threadID: "performance-thread-1")
        let second = MailListRowID(accountID: "ui-audit", threadID: "performance-thread-3")
        let messageIDs = [first: "performance-1", second: "performance-3"]
        _ = await gmail.modifyThreads(ids: [first.threadID, second.threadID], addLabelIDs: [SystemLabel.unread], removeLabelIDs: [])
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            for (index, row) in [first, second].enumerated() {
                guard let messageID = messageIDs[row] else { continue }
                let message = MessageRecord(accountID: row.accountID, id: messageID, threadID: row.threadID, historyID: 200,
                    date: Date(timeIntervalSince1970: Double(2 - index)), snippet: "Synthetic delayed content",
                    sender: "Sender <sender@example.invalid>", recipients: "me@example.invalid", cc: nil,
                    subject: "Delayed message \(index)", sizeEstimate: 1)
                try tx.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox, SystemLabel.unread])])
                try tx.rebuildThreads([row.threadID], accountID: row.accountID)
            }
        }
        let suite = "tern.selection.loading." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        settings.set(false, forKey: MailWindowPreferences.hidesReaderKey)
        let preferences = MessageListPreferences(defaults: settings)
        let account = AccountRecord(id: first.accountID, email: "me@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: cache, gmail: gmail,
            outgoingDirectory: FileManager.default.temporaryDirectory, syncEnabled: false, listPreferences: preferences)
        var sharedLoad: Task<Bool, Never>?
        defer {
            sharedLoad?.cancel()
            Task { await gate.cancelAll(); await mailbox.stop() }
            settings.removePersistentDomain(forName: suite)
        }
        await mailbox.start()
        try await awaitListState("two delayed-reader rows", details: { "rows=\(mailbox.listItems.map(\.id))" }) {
            mailbox.isListPresentationReady && Set(mailbox.listItems.map(\.id)) == [first, second]
        }

        var rendered: [MailListRowID: MessageListRow.RenderState] = [:]
        let oldBodyHook = MessageListRow.onBodyEvaluation
        MessageListRow.onBodyEvaluation = { owner, id, state in
            oldBodyHook?(owner, id, state)
            if owner === mailbox { rendered[id] = state }
        }
        defer { MessageListRow.onBodyEvaluation = oldBodyHook }
        let app = AppModel()
        let controller = NSHostingController(rootView: SelectionMailColumns(mailbox: mailbox)
            .frame(width: 1_280, height: 760).environment(app).defaultAppStorage(settings))
        let window = SelectionReaderWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close() }
        func listProbes(in view: NSView) -> [MailColumnProbe.ProbeView] {
            if let probe = view as? MailColumnProbe.ProbeView {
                return probe.pane == .list && probe.window === window ? [probe] : []
            }
            return view.subviews.flatMap { listProbes(in: $0) }
        }
        func nativeTable() -> NSTableView? {
            let probes = listProbes(in: controller.view)
            guard probes.count == 1, let probe = probes.first else { return nil }
            var column: NSView = probe
            while let parent = column.superview {
                if let split = parent as? NSSplitView, split.isVertical {
                    guard !split.isSubviewCollapsed(column) else { return nil }
                    let tables = listTables(in: column)
                    return tables.count == 1 ? tables.first : nil
                }
                column = parent
            }
            return nil
        }
        try await awaitListState("production mail-columns native table", details: {
            "rows=\(nativeTable()?.numberOfRows ?? -1), viewport=\(String(describing: nativeTable()?.visibleRect))"
                + ", listProbes=\(listProbes(in: controller.view).count), allTableRows=\(listTables(in: controller.view).map(\.numberOfRows))"
        }) { nativeTable()?.numberOfRows == 2 && (nativeTable()?.visibleRect.width ?? 0) > 200 }
        let table = try #require(nativeTable())
        let scroll = try #require(table.enclosingScrollView)
        func selected(_ row: MailListRowID) -> Bool {
            guard let index = mailbox.listItems.firstIndex(where: { $0.id == row }),
                  let nativeRow = table.rowView(atRow: index, makeIfNecessary: false) else { return false }
            return nativeTable() === table && table.enclosingScrollView === scroll
                && table.selectedRowIndexes == IndexSet(integer: index) && nativeRow.isSelected
                && nativeRow.window === window && table.rect(ofRow: index).intersects(table.visibleRect)
                && mailbox.selectedListRowIDs == [row] && rendered[row]?.selected == true
                && rendered[row == first ? second : first]?.selected != true
        }
        func bodyExists(_ row: MailListRowID) async throws -> Bool {
            let messageID = try #require(messageIDs[row])
            return try await cache.read { try $0.body(messageID: messageID, accountID: row.accountID) != nil }
        }

        // A second reader may already own this foreground load. Keeping that
        // known waiter alive makes A's late completion deterministic, without
        // guessing whether an unobserved task joined before selection changed.
        sharedLoad = Task { await mailbox.open(first.threadKey, markRead: false) }
        try await awaitLoadingState("shared A fetch held") { await gate.started(first.threadID, priority: .interactive) }
        #expect(try await !bodyExists(first))
        let firstIndex = try #require(mailbox.listItems.firstIndex { $0.id == first })
        table.selectRowIndexes(IndexSet(integer: firstIndex), byExtendingSelection: false)
        try await awaitListState("native A selected while body is blocked", details: { "native=\(table.selectedRowIndexes), model=\(mailbox.selectedListRowIDs)" }) {
            selected(first)
        }
        #expect(try await !bodyExists(first))

        mailbox.selectListRows([second])
        let generation = try #require(NavigationPerformance.shared.currentGeneration(for: .reader))
        func selectedReaderHasReadableContent() -> Bool {
            let performance = NavigationPerformance.shared
            return performance.isReady(.reader, generation: generation)
                || performance.records.contains { $0.kind == .reader && $0.generation == generation && $0.outcome == .visibleCommit }
        }
        defer {
            NavigationPerformance.shared.cancel(.reader, generation: generation)
            NavigationPerformance.shared.cancel(.readerHeader)
            NavigationPerformance.shared.cancel(.selectionFeedback)
        }
        // syncEnabled:false also disables speculative prefetch. The interactive
        // request is a positive witness that the mounted reader actually ran.
        try await awaitLoadingState("selected B foreground fetch held") { await gate.started(second.threadID, priority: .interactive) }
        try await awaitListState("native B selected before either body arrives", details: { "native=\(table.selectedRowIndexes), model=\(mailbox.selectedListRowIDs)" }) {
            selected(second)
        }
        #expect(try await !bodyExists(first))
        #expect(try await !bodyExists(second))
        #expect(!selectedReaderHasReadableContent())

        // An active-reader read change is the positive control for the hidden
        // reader's absence of effects. Timer cancellation has separate coverage.
        settings.set(ReadingPreferences.MarkRead.immediately.rawValue, forKey: ReadingPreferences.markReadKey)
        try await awaitLoadingState("only active B is marked read") {
            try await cache.read { tx in
                try tx.currentLabels(threadID: second.threadID, accountID: second.accountID)["performance-3"]?.contains(SystemLabel.unread) == false
            }
        }
        await gate.release(first.threadID)
        #expect(await sharedLoad?.value == true)
        try await awaitLoadingState("older A body really published") { try await bodyExists(first) }
        #expect(try await !bodyExists(second))
        try await awaitListState("late A completion preserves native B", details: { "native=\(table.selectedRowIndexes), model=\(mailbox.selectedListRowIDs)" }) {
            selected(second)
        }

        await gate.release(second.threadID)
        try await awaitLoadingState("B body delivered and current reader reports readable content") {
            try await bodyExists(second) && selectedReaderHasReadableContent()
        }
        try await awaitListState("completed B remains selected", details: { "native=\(table.selectedRowIndexes), model=\(mailbox.selectedListRowIDs)" }) {
            selected(second)
        }
        let actions = try await cache.read { try $0.allActions(accountID: first.accountID) }
        #expect(!actions.contains { $0.threadIDs.contains(first.threadID) || $0.messageIDs.contains("performance-1") })
        #expect(actions.contains { $0.threadIDs.contains(second.threadID) && $0.removeLabelIDs.contains(SystemLabel.unread) })
        #expect(try await cache.read {
            try $0.currentLabels(threadID: first.threadID, accountID: first.accountID)["performance-1"]?.contains(SystemLabel.unread)
        } == true)
    }

    private func awaitLoadingState(_ phase: String, sourceLocation: SourceLocation = #_sourceLocation,
                                   _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(try await condition(), "\(phase)", sourceLocation: sourceLocation)
    }

    private func listTables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { listTables(in: $0) }
    }

    /// Distinguishes an eager binding read from List's later binding use.
    /// This is an API dependency probe, separate from the hosted row counts.
    private func selectionObservationCounts(_ mailbox: MailboxModel, target: MailListRowID) -> String {
        let previousSelection = mailbox.selectedListRowIDs
        let previousNotice = mailbox.notice
        mailbox.selectListRows([])
        defer { mailbox.selectListRows(previousSelection); mailbox.notice = previousNotice }
        let bindingReads = Mutex(0), listReads = Mutex(0), directReads = Mutex(0)
        let binding = Bindable(mailbox).selectedListRowIDs
        withObservationTracking { _ = Bindable(mailbox).selectedListRowIDs } onChange: {
            bindingReads.withLock { $0 += 1 }
        }
        withObservationTracking { _ = List(selection: binding) { Text("Probe").tag(target) } } onChange: {
            listReads.withLock { $0 += 1 }
        }
        withObservationTracking { _ = mailbox.selectedListRowIDs } onChange: {
            directReads.withLock { $0 += 1 }
        }
        mailbox.notice = .init(message: "Synthetic unrelated list probe")
        #expect(bindingReads.withLock { $0 } == 0 && listReads.withLock { $0 } == 0 && directReads.withLock { $0 } == 0,
            "An unrelated notice must not invalidate selection dependencies")
        mailbox.selectListRows([target])
        #expect(directReads.withLock { $0 } == 1, "Direct selection read is the positive observation control")
        return "binding=\(bindingReads.withLock { $0 }), list=\(listReads.withLock { $0 }), direct=\(directReads.withLock { $0 })"
    }

    private func awaitListState(_ phase: String, details: () -> String,
                                sourceLocation: SourceLocation = #_sourceLocation,
                                _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition(), "\(phase): \(details())", sourceLocation: sourceLocation)
    }
    #endif

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

#if DEBUG || TERN_PERFORMANCE
private struct SelectionMailColumns: View {
    let mailbox: MailboxModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var sidebarWidth = Tokens.Layout.sidebarWidth + Tokens.Layout.columnGutter
    @State private var paneSizing = AssistantMailPaneSizing()
    @State private var toolbarInset = ClippedSplitToolbarInset()
    @FocusState private var outboxFocused: Bool

    var body: some View {
        MailColumnsContent(mailbox: mailbox,
            identity: .init(columnVisibility: columnVisibility, showsReader: true, showsAssistant: false,
                topInset: toolbarInset.top, outboxFocused: outboxFocused),
            columnVisibility: $columnVisibility, sidebarColumnWidth: $sidebarWidth,
            outboxFocused: $outboxFocused, paneSizing: paneSizing, toolbarInset: toolbarInset)
            .equatable()
            .navigationSplitViewStyle(.balanced)
    }
}

/// Simulates a visible reader without activating or raising the test window.
/// This tests native selection and loading order, not onscreen pixels or latency.
@MainActor private final class SelectionReaderWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState { .visible }
}

private actor SelectionBodyGate {
    private var starts: [String: Set<GmailRequestBudget.Priority>] = [:]
    private var released: Set<String> = []
    private var waiters: [String: [UUID: CheckedContinuation<Void, any Error>]] = [:]

    func started(_ id: String, priority: GmailRequestBudget.Priority) -> Bool {
        starts[id]?.contains(priority) == true
    }

    func wait(_ id: String, priority: GmailRequestBudget.Priority) async throws {
        try Task.checkCancellation()
        starts[id, default: []].insert(priority)
        guard !released.contains(id) else { return }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id, default: [:]][token] = continuation }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(id, token: token) }
        }
    }

    func release(_ id: String) {
        released.insert(id)
        for continuation in waiters.removeValue(forKey: id)?.values ?? [:].values { continuation.resume() }
    }

    func cancelAll() {
        let pending = waiters
        waiters = [:]
        for group in pending.values {
            for continuation in group.values { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func cancel(_ id: String, token: UUID) {
        waiters[id]?.removeValue(forKey: token)?.resume(throwing: CancellationError())
    }
}
#endif
