import MailStore

/// A row's location is distinct from the mailbox it opens. Favorites may
/// repeat destinations that also appear under an account or saved search.
struct SidebarRowSelection: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case favorite(String), mailboxes, savedSearch
    }

    let source: Source
    let mailbox: MailboxID

    init(source: Source = .mailboxes, mailbox: MailboxID) {
        self.source = source
        self.mailbox = mailbox
    }
}

struct SidebarLabelItem: Identifiable {
    let node: LabelNode
    let depth: Int
    var id: String { node.id }
}

extension MailboxModel {
    func sidebarLabelRows(for owner: AccountMailbox, expandedLabels: Set<MailboxID>) -> [SidebarLabelItem] {
        func flatten(_ nodes: [LabelNode], depth: Int) -> [SidebarLabelItem] {
            nodes.flatMap { node in
                let row = SidebarLabelItem(node: node, depth: depth)
                guard expandedLabels.contains(.account(owner.account.id, node.id)), let children = node.children else { return [row] }
                return [row] + flatten(children, depth: depth + 1)
            }
        }
        return flatten(sidebarLabelOutline(for: owner), depth: 0)
    }

    func sidebarLabelAncestors(of box: MailboxID) -> [MailboxID] {
        guard let path = sidebarLabelPath(of: box) else { return [] }
        return path.dropLast().map { .account($0.label.accountID, $0.id) }
    }

    func sidebarLabelHasChildren(box: MailboxID) -> Bool {
        sidebarLabelPath(of: box)?.last?.children?.isEmpty == false
    }

    func sidebarRowSelection(
        preferred: SidebarRowSelection?, favoritesCollapsed: Bool, expandedMailboxIDs: Set<String>
    ) -> SidebarRowSelection? {
        guard let destination = sidebarSelection else { return nil }
        let rows = sidebarRows(favoritesCollapsed: favoritesCollapsed, expandedMailboxIDs: expandedMailboxIDs)
        var matches = rows.filter { $0.mailbox == destination }
        if matches.isEmpty, case .scoped = destination {
            // Profiles can hide part of a saved scope without rewriting its
            // destination. Match the row representing those remaining accounts.
            let accountIDs = Set(sidebarAccounts(for: destination).map(\.account.id))
            if !accountIDs.isEmpty {
                matches = rows.filter {
                    $0.mailbox.id == destination.id && Set(sidebarAccounts(for: $0.mailbox).map(\.account.id)) == accountIDs
                }
            }
        }
        if let preferred, let row = matches.first(where: { $0.source == preferred.source }) { return row }
        return matches.first
    }

    /// Resolve before revealing a programmatic destination. Explicit disclosure
    /// changes use sidebarRowSelection instead, so collapsing stays collapsed.
    func sidebarRowForNavigation(preferred: SidebarRowSelection? = nil) -> SidebarRowSelection? {
        let ids = Set((SystemMailbox.all + [.outbox]).map(\.id)
            + navigation.favorites.compactMap { favoriteMailboxID($0.target)?.id })
        return sidebarRowSelection(preferred: preferred, favoritesCollapsed: false, expandedMailboxIDs: ids)
    }

    func sidebarAccounts(for box: MailboxID) -> [AccountMailbox] {
        switch box {
        case .combined: presentedAccounts
        case .account(let id, _): presentedAccounts.filter { $0.account.id == id }
        case .scoped(_, let ids): presentedAccounts.filter { ids.contains($0.account.id) }
        }
    }

    func sidebarCanExpand(_ row: SidebarRowSelection) -> Bool {
        guard sidebarAccounts(for: row.mailbox).count > 1 else { return false }
        switch row.source {
        case .favorite(let id):
            return navigation.favorites.first(where: { $0.id == id })
                .flatMap { favoriteMailboxID($0.target) } == row.mailbox
        case .mailboxes:
            guard case .combined = row.mailbox else { return false }
            return (SystemMailbox.all + [.outbox]).contains { $0.id == row.mailbox.id }
        case .savedSearch:
            return false
        }
    }

    func sidebarParent(of row: SidebarRowSelection) -> SidebarRowSelection? {
        guard case .account(let accountID, let labelID) = row.mailbox else { return nil }
        let isCategory = accountPresentation[accountID]?.inboxCategories.contains(where: { $0.labelID == labelID }) == true
        switch row.source {
        case .favorite(let id):
            guard let favorite = navigation.favorites.first(where: { $0.id == id }),
                  let parent = favoriteMailboxID(favorite.target), parent != row.mailbox,
                  sidebarAccounts(for: parent).contains(where: { $0.account.id == accountID })
            else { return nil }
            if isCategory, parent.id == SystemLabel.inbox {
                return SidebarRowSelection(source: row.source, mailbox: .account(accountID, SystemLabel.inbox))
            }
            guard parent.id == labelID else { return nil }
            return SidebarRowSelection(source: row.source, mailbox: parent)
        case .mailboxes:
            if let parent = sidebarLabelAncestors(of: row.mailbox).last {
                return SidebarRowSelection(mailbox: parent)
            }
            if isCategory, !unifiedFavoriteMailboxIDs.contains(SystemLabel.inbox) {
                return SidebarRowSelection(mailbox: .account(accountID, SystemLabel.inbox))
            }
            guard presentedAccounts.count > 1,
                  (SystemMailbox.all + [.outbox]).contains(where: { $0.id == labelID }),
                  !unifiedFavoriteMailboxIDs.contains(labelID) else { return nil }
            return SidebarRowSelection(mailbox: .combined(labelID))
        case .savedSearch:
            return nil
        }
    }

    private var unifiedFavoriteMailboxIDs: Set<String> {
        Set(navigation.favorites.compactMap {
            if case .mailbox(let id, .allAccounts) = $0.target { return id }
            return nil
        })
    }

    private func sidebarRows(favoritesCollapsed: Bool, expandedMailboxIDs: Set<String>) -> [SidebarRowSelection] {
        var parents: [SidebarRowSelection] = []
        var children: [SidebarRowSelection] = []
        if !favoritesCollapsed {
            for favorite in navigation.favorites {
                guard let box = favoriteMailboxID(favorite.target) else { continue }
                let source = SidebarRowSelection.Source.favorite(favorite.id)
                parents.append(SidebarRowSelection(source: source, mailbox: box))
                let owners = sidebarAccounts(for: box)
                if owners.count > 1, expandedMailboxIDs.contains(box.id) {
                    for owner in owners {
                        children.append(SidebarRowSelection(source: source, mailbox: .account(owner.account.id, box.id)))
                        if box.id == SystemLabel.inbox { children += sidebarCategoryRows(owner.account.id, source: source) }
                    }
                } else if box.id == SystemLabel.inbox, owners.count == 1, let owner = owners.first {
                    children += sidebarCategoryRows(owner.account.id, source: source)
                }
            }
        }
        // Direct favorites win over account children when a command opens a
        // destination that appears more than once. A clicked source wins above.
        var rows = parents + children
        for search in navigation.searches {
            if let box = favoriteMailboxID(.savedSearch(id: search.id)) {
                rows.append(SidebarRowSelection(source: .savedSearch, mailbox: box))
            }
        }
        let hidden = unifiedFavoriteMailboxIDs
        for box in SystemMailbox.all + [.outbox] where !hidden.contains(box.id) {
            let combined = MailboxID.combined(box.id)
            if presentedAccounts.count > 1 {
                guard box.id != Self.outboxID || showsOutbox(combined) else { continue }
                rows.append(SidebarRowSelection(mailbox: combined))
                guard expandedMailboxIDs.contains(box.id) else { continue }
            }
            for owner in presentedAccounts {
                let accountBox = MailboxID.account(owner.account.id, box.id)
                guard box.id != Self.outboxID || showsOutbox(accountBox) else { continue }
                rows.append(SidebarRowSelection(mailbox: accountBox))
                if box.id == SystemLabel.inbox { rows += sidebarCategoryRows(owner.account.id, source: .mailboxes) }
            }
        }
        for owner in presentedAccounts {
            for label in owner.labels where !LabelRules.isTemporary(label.id) {
                if !label.isSystem, isVisibleInSidebar(label) || listPreferences.showsMore {
                    rows.append(SidebarRowSelection(mailbox: .account(owner.account.id, label.id)))
                } else if label.isSystem, listPreferences.showsMore,
                          !(SystemMailbox.all.map(\.id) + [SystemLabel.unread]).contains(label.id),
                          accountPresentation[owner.account.id]?.inboxCategories.contains(where: { $0.labelID == label.id }) != true {
                    rows.append(SidebarRowSelection(mailbox: .account(owner.account.id, label.id)))
                }
            }
        }
        return rows
    }

    private func sidebarCategoryRows(_ accountID: String, source: SidebarRowSelection.Source) -> [SidebarRowSelection] {
        InboxCategory.allCases.filter { accountPresentation[accountID]?.inboxCategories.contains($0) == true }.map {
            SidebarRowSelection(source: source, mailbox: .account(accountID, $0.labelID))
        }
    }

    private func sidebarLabelOutline(for owner: AccountMailbox) -> [LabelNode] {
        owner.sidebarLabelOutline
    }

    private func sidebarLabelPath(of box: MailboxID) -> [LabelNode]? {
        guard case .account(let accountID, let labelID) = box,
              let owner = presentedAccounts.first(where: { $0.account.id == accountID }) else { return nil }
        func path(in nodes: [LabelNode]) -> [LabelNode]? {
            for node in nodes {
                if node.id == labelID { return [node] }
                if let children = node.children, let nested = path(in: children) { return [node] + nested }
            }
            return nil
        }
        return path(in: sidebarLabelOutline(for: owner))
    }
}
