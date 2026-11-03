import Foundation
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct SidebarSelectionTests {
    @Test func duplicateDestinationsKeepTheirClickedRowAndCollapsePreservesNavigation() async throws {
        try await withMailbox { mailbox in
            let target = MailFavoriteTarget.label(accountID: "a", labelID: "projects")
            #expect(await mailbox.navigation.addFavorite(target))
            let favorite = try #require(mailbox.navigation.favorites.first { $0.target == target })
            let box = MailboxID.account("a", "projects")
            let shortcut = SidebarRowSelection(source: .favorite(favorite.id), mailbox: box)
            let label = SidebarRowSelection(mailbox: box)
            mailbox.sidebarSelection = box

            #expect(selection(mailbox, preferred: shortcut) == shortcut)
            #expect(selection(mailbox, preferred: label) == label)
            #expect(selection(mailbox, preferred: nil) == shortcut)
            #expect(mailbox.sidebarRowSelection(preferred: shortcut, favoritesCollapsed: true, expandedMailboxIDs: []) == label)
            mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "retained")]
            mailbox.sidebarSelection = nil
            #expect(mailbox.selectedMailbox == box)
            #expect(mailbox.selectedThreadIDs == [ThreadKey(accountID: "a", threadID: "retained")])
            #expect(selection(mailbox, preferred: shortcut) == shortcut)

            await mailbox.navigation.removeFavorite(favorite.id)
            #expect(selection(mailbox, preferred: shortcut) == label)
        }
    }

    @Test func oneAccountAliasesAndProfileChangesKeepThePreferredFavorite() async throws {
        try await withMailbox { mailbox in
            let target = MailFavoriteTarget.mailbox(labelID: SystemLabel.inbox, scope: .accounts(["a"]))
            #expect(await mailbox.navigation.addFavorite(target))
            let accountFavorite = try #require(mailbox.navigation.favorites.first { $0.target == target })
            let unifiedFavorite = try #require(mailbox.navigation.favorites.first {
                $0.target == .mailbox(labelID: SystemLabel.inbox, scope: .allAccounts)
            })
            mailbox.selectedMailbox = .combined(SystemLabel.inbox)
            let unified = SidebarRowSelection(source: .favorite(unifiedFavorite.id), mailbox: .combined(SystemLabel.inbox))
            mailbox.applyAccountPresentation(preferences: [], visibleAccountIDs: ["a"])
            let box = MailboxID.account("a", SystemLabel.inbox)
            #expect(mailbox.selectedMailbox == box)
            #expect(selection(mailbox, preferred: unified) == SidebarRowSelection(source: unified.source, mailbox: box))
            let account = SidebarRowSelection(source: .favorite(accountFavorite.id), mailbox: box)
            #expect(selection(mailbox, preferred: account) == account)
            #expect(mailbox.sidebarRowSelection(preferred: account, favoritesCollapsed: true, expandedMailboxIDs: []) == nil)
            #expect(mailbox.sidebarRowForNavigation(preferred: account) == account)
            #expect(!mailbox.sidebarCanExpand(account))
            mailbox.applyAccountPresentation(preferences: [], visibleAccountIDs: ["a", "b"])
            let scopedTarget = MailFavoriteTarget.mailbox(labelID: SystemLabel.inbox, scope: .accounts(["a", "b"]))
            #expect(await mailbox.navigation.addFavorite(scopedTarget))
            let scopedFavorite = try #require(mailbox.navigation.favorites.first { $0.target == scopedTarget })
            let scoped = SidebarRowSelection(source: .favorite(scopedFavorite.id), mailbox: .scoped(SystemLabel.inbox, ["a", "b"]))
            mailbox.selectedMailbox = scoped.mailbox
            mailbox.applyAccountPresentation(preferences: [], visibleAccountIDs: ["a"])
            #expect(mailbox.selectedMailbox == scoped.mailbox)
            #expect(selection(mailbox, preferred: scoped) == SidebarRowSelection(source: scoped.source, mailbox: box))
        }
    }

    @Test func scopedFavoriteChildrenNavigateToTheirOwnParent() async throws {
        try await withMailbox { mailbox in
            let target = MailFavoriteTarget.mailbox(labelID: SystemLabel.inbox, scope: .accounts(["a", "b"]))
            #expect(await mailbox.navigation.addFavorite(target))
            let favorite = try #require(mailbox.navigation.favorites.first { $0.target == target })
            let source = SidebarRowSelection.Source.favorite(favorite.id)
            let parent = SidebarRowSelection(source: source, mailbox: .scoped(SystemLabel.inbox, ["a", "b"]))
            let child = SidebarRowSelection(source: source, mailbox: .account("a", SystemLabel.inbox))
            #expect(mailbox.sidebarCanExpand(parent))
            #expect(!mailbox.sidebarCanExpand(child))
            #expect(mailbox.sidebarParent(of: child) == parent)
            mailbox.accountPresentation["a"] = AccountMailPreferences(accountID: "a", inboxCategories: [.promotions])
            let category = SidebarRowSelection(source: source, mailbox: .account("a", InboxCategory.promotions.labelID))
            #expect(mailbox.sidebarParent(of: category) == child)
            mailbox.sidebarSelection = category.mailbox
            #expect(selection(mailbox, preferred: category) == category)
            #expect(mailbox.sidebarRowForNavigation(preferred: category) == category)
            let categoryTarget = MailFavoriteTarget.mailbox(labelID: InboxCategory.promotions.labelID, scope: .accounts(["a"]))
            #expect(await mailbox.navigation.addFavorite(categoryTarget))
            let categoryFavorite = try #require(mailbox.navigation.favorites.first { $0.target == categoryTarget })
            let categoryShortcut = SidebarRowSelection(source: .favorite(categoryFavorite.id), mailbox: category.mailbox)
            #expect(mailbox.sidebarParent(of: categoryShortcut) == nil)
        }
    }

    @Test func scopedSavedSearchCommandsAndDuplicateRowsShareOneDestination() async throws {
        try await withMailbox { mailbox in
            let saved = SavedMailSearch(id: "scoped", name: "Projects", query: "project", scope: .accounts(["a"]))
            #expect(await mailbox.navigation.saveSearch(saved))
            #expect(await mailbox.navigation.addFavorite(.savedSearch(id: saved.id)))
            let favorite = try #require(mailbox.navigation.favorites.first { $0.target == .savedSearch(id: saved.id) })
            let destination = try #require(mailbox.favoriteMailboxID(.savedSearch(id: saved.id)))
            mailbox.openSavedSearch(saved)
            #expect(mailbox.sidebarSelection == destination)
            #expect(destination == .scoped(MailNavigationModel.searchPrefix + saved.id, ["a"]))
            let search = SidebarRowSelection(source: .savedSearch, mailbox: destination)
            let shortcut = SidebarRowSelection(source: .favorite(favorite.id), mailbox: destination)
            #expect(selection(mailbox, preferred: search) == search)
            #expect(selection(mailbox, preferred: shortcut) == shortcut)
            mailbox.sidebarSelection = nil
            #expect(mailbox.selectedMailbox == destination)
            #expect(mailbox.search.isActive)

            mailbox.applyAccountPresentation(preferences: [], visibleAccountIDs: ["b"])
            let previous = mailbox.selectedMailbox
            mailbox.openSavedSearch(saved)
            #expect(mailbox.selectedMailbox == previous)
        }
    }

    @Test func clearingNativeSelectionDoesNotCancelSearchButChoosingMailboxDoes() async throws {
        try await withMailbox { mailbox in
            let box = MailboxID.account("a", SystemLabel.inbox)
            mailbox.sidebarSelection = box
            mailbox.search.update("project")
            #expect(mailbox.sidebarSelection == nil)
            mailbox.sidebarSelection = nil
            #expect(mailbox.selectedMailbox == box)
            #expect(mailbox.search.isActive)
            mailbox.sidebarSelection = box
            #expect(!mailbox.search.isActive)
            #expect(mailbox.sidebarSelection == box)
        }
    }

    @Test func nestedLabelsRevealExistingAncestorsAndRespectExpansionAndAccountOwnership() async throws {
        try await withMailbox { mailbox in
            let owner = try #require(mailbox.account(id: "a"))
            let labels = [
                LabelRecord(accountID: "a", id: "work", name: "Work", isSystem: false),
                LabelRecord(accountID: "a", id: "acme", name: "Work/Clients/Acme", isSystem: false),
                LabelRecord(accountID: "a", id: "year", name: "Work/Clients/Acme/2026", isSystem: false),
                LabelRecord(accountID: "a", id: "receipts", name: "Old/Receipts", isSystem: false),
                LabelRecord(accountID: "a", id: "hidden", name: "Hidden", isSystem: false, labelListVisibility: "labelHide"),
                LabelRecord(accountID: "a", id: "nested", name: "Hidden/Nested", isSystem: false)
            ]
            try await mailbox.cache.write { try $0.replaceLabels(labels, accountID: "a") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !owner.labels.contains(where: { $0.id == "year" }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(owner.labels.contains { $0.id == "year" })
            let collapsed = mailbox.sidebarLabelRows(for: owner, expandedLabels: [])
            #expect(collapsed.map(\.node.title) == ["Hidden/Nested", "Old/Receipts", "Work"])
            #expect(collapsed.map(\.depth) == [0, 0, 0])
            let work = MailboxID.account("a", "work")
            let acme = MailboxID.account("a", "acme")
            let year = MailboxID.account("a", "year")
            let ancestors = mailbox.sidebarLabelAncestors(of: year)
            #expect(ancestors == [work, acme])
            #expect(mailbox.sidebarParent(of: SidebarRowSelection(mailbox: year))?.mailbox == acme)
            #expect(mailbox.sidebarParent(of: SidebarRowSelection(mailbox: acme))?.mailbox == work)
            #expect(mailbox.sidebarLabelAncestors(of: .account("a", "receipts")).isEmpty)
            #expect(mailbox.sidebarLabelAncestors(of: .account("a", "nested")).isEmpty)
            #expect(mailbox.sidebarLabelAncestors(of: .account("b", "year")).isEmpty)
            #expect(mailbox.sidebarLabelHasChildren(box: work))
            #expect(!mailbox.sidebarLabelHasChildren(box: year))
            let expanded = mailbox.sidebarLabelRows(for: owner, expandedLabels: Set(ancestors))
            #expect(expanded.map(\.node.title) == ["Hidden/Nested", "Old/Receipts", "Work", "Clients/Acme", "2026"])
            #expect(expanded.map(\.depth) == [0, 0, 0, 1, 2])
            let partlyCollapsed = mailbox.sidebarLabelRows(for: owner, expandedLabels: [work])
            #expect(partlyCollapsed.map(\.id) == ["nested", "receipts", "work", "acme"])
        }
    }

    @Test func nestedLabelUsesTheClickedAccountsParentWithoutApplyingTheCurrentSelection() async throws {
        try await withMailbox { mailbox in
            mailbox.selectedMailbox = .account("a", SystemLabel.inbox)
            mailbox.selectedThreadIDs = [ThreadKey(accountID: "a", threadID: "selected")]
            let parent = try #require(mailbox.account(id: "b")?.labels.first { $0.id == "projects" })

            mailbox.showNewNestedLabel(under: parent)

            let request = try #require(mailbox.labelEditor)
            #expect(request.accountID == "b")
            #expect(request.draft.name.isEmpty)
            #expect(request.draft.parent == "Projects")
            if case .new(let applyingTo) = request.kind {
                #expect(applyingTo.isEmpty)
            } else {
                Issue.record("A nested label must open the create editor")
            }
            var draft = request.draft
            draft.name = "Invoices"
            #expect(draft.fullName == "Projects/Invoices")
            #expect(mailbox.parentChoices(for: nil).contains("Projects"))
            #expect(mailbox.selectedMailbox == .account("a", SystemLabel.inbox))

            mailbox.labelEditor = nil
            let inbox = try #require(mailbox.account(id: "b")?.labels.first { $0.id == SystemLabel.inbox })
            for unavailable in [inbox,
                LabelRecord(accountID: "b", id: LabelRules.temporaryPrefix + "pending", name: "Pending", isSystem: false),
                LabelRecord(accountID: "b", id: "deleted", name: "Deleted", isSystem: false)] {
                mailbox.showNewNestedLabel(under: unavailable)
                #expect(mailbox.labelEditor == nil)
            }
        }
    }

    private func selection(_ mailbox: MailboxModel, preferred: SidebarRowSelection?) -> SidebarRowSelection? {
        mailbox.sidebarRowSelection(preferred: preferred, favoritesCollapsed: false, expandedMailboxIDs: [SystemLabel.inbox])
    }

    private func withMailbox(_ body: (MailboxModel) async throws -> Void) async throws {
        let store = try AccountStore.inMemory()
        let cache = try MailCache.inMemory()
        let accounts = ["a", "b"].map {
            AccountRecord(id: $0, email: "\($0)@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        }
        for account in accounts {
            try await store.save(account)
            try await cache.write { transaction in
                try transaction.replaceLabels([
                    LabelRecord(accountID: account.id, id: SystemLabel.inbox, name: "Inbox", isSystem: true),
                    LabelRecord(accountID: account.id, id: "projects", name: "Projects", isSystem: false)
                ], accountID: account.id)
            }
        }
        let mailbox = MailboxModel(account: accounts[0], cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory, snoozeStore: store, syncEnabled: false)
        await mailbox.addAccount(accounts[1], gmail: AuditGmail(), syncEnabled: false)
        await mailbox.start()
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while mailbox.accounts.contains(where: { $0.labels.isEmpty }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(mailbox.accounts.allSatisfy { !$0.labels.isEmpty })
            try await body(mailbox)
            await mailbox.stop()
        } catch {
            await mailbox.stop()
            throw error
        }
    }
}
