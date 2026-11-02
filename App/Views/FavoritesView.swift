import MailStore
import SwiftUI

struct FavoritesView: View {
    @Environment(\.sidebarRowSize) private var sidebarRowSize
    let mailbox: MailboxModel
    @AppStorage(SidebarExpansion.storageKey) private var expanded = SidebarExpansion.initial
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()
    @Binding var isCollapsed: Bool
    @Binding var isAddingFavorite: Bool
    @State private var hoveredFavorite: String?
    @State private var isHeaderHovered = false
    @FocusState private var focusedControl: HeaderControl?
    @AccessibilityFocusState private var isHeaderAccessibilityFocused: Bool

    private enum HeaderControl: Hashable { case add, disclosure }

    private var showsHeaderControls: Bool {
        isHeaderHovered || focusedControl != nil || isHeaderAccessibilityFocused || isAddingFavorite
    }

    var body: some View {
        Section {
            if !isCollapsed {
                ForEach(mailbox.navigation.favorites) { favorite in
                    if let box = mailbox.favoriteMailboxID(favorite.target) {
                        favoriteRows(favorite, box: box)
                    }
                }
                .onMove { source, destination in
                    Task { await mailbox.navigation.moveFavorites(fromOffsets: source, toOffset: destination) }
                }
            }
        } header: {
            header
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Space.s1) {
            Text("Favorites")
            Spacer(minLength: Tokens.Space.s1)
            Button { isAddingFavorite = true } label: {
                Image(systemName: "plus.circle")
                    .font(.body)
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .contentShape(Rectangle())
                    .ternHover()
                    .opacity(showsHeaderControls ? 1 : 0)
            }
            .buttonStyle(.borderless)
            .focusable()
            .focused($focusedControl, equals: .add)
            .onKeyPress(keys: [.return, .space]) { _ in
                isAddingFavorite = true
                return .handled
            }
            .accessibilityLabel("Add Favorite")
            .accessibilityIdentifier("favorites.add")
            .help("Add Favorite")

            Button { isCollapsed.toggle() } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .contentShape(Rectangle())
                    .ternHover()
                    .opacity(showsHeaderControls ? 1 : 0)
                    .ternAnimation(value: isCollapsed)
            }
            .buttonStyle(.borderless)
            .focusable()
            .focused($focusedControl, equals: .disclosure)
            .onKeyPress(keys: [.return, .space]) { _ in
                isCollapsed.toggle()
                return .handled
            }
            .accessibilityLabel(isCollapsed ? "Expand Favorites" : "Collapse Favorites")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("favorites.disclosure")
            .help(isCollapsed ? "Expand Favorites" : "Collapse Favorites")
        }
        .padding(.vertical, Tokens.Space.s1_5)
        .contentShape(Rectangle())
        // macOS combines section headers into one heading, so expose both actions there.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Favorites")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("favorites.header")
        .accessibilityFocused($isHeaderAccessibilityFocused)
        .accessibilityAction(named: Text("Add Favorite")) { isAddingFavorite = true }
        .accessibilityAction(named: Text(isCollapsed ? "Expand Favorites" : "Collapse Favorites")) { isCollapsed.toggle() }
        .onHover { isHeaderHovered = $0 }
        .contextMenu {
            Button("Add Favorite…", systemImage: "plus") { isAddingFavorite = true }
            Button("Add Current Mailbox") { addCurrent() }
                .disabled(mailbox.selectedLabelID == nil || mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID)
            Button("New Saved Search…") { mailbox.navigation.isCreatingSearch = true }
            Divider()
            Button("Reset Favorites") { Task { await mailbox.navigation.resetFavorites() } }
        }
    }

    @ViewBuilder private func favoriteRows(_ favorite: MailFavorite, box: MailboxID) -> some View {
        let source = SidebarRowSelection.Source.favorite(favorite.id)
        let isExpanded = expanded.ids.contains(box.id)
        let canExpand = accounts(for: box).count > 1
        HStack(spacing: Tokens.Space.s1) {
            Label {
                Text(title(favorite)).lineLimit(1)
            } icon: {
                let scale = Tokens.Control.sidebarIconScale(sidebarRowSize)
                Image(systemName: symbol(favorite))
                    .font(.system(size: Tokens.Control.icon * scale))
                    .imageScale(.medium)
                    .foregroundStyle(SidebarSymbolStyle(color: color(favorite)))
                    .frame(width: Tokens.Space.s5 * scale)
            }
            Spacer(minLength: Tokens.Space.s1)
            if canExpand {
                SidebarDisclosureButton(title: title(favorite), isExpanded: isExpanded, isHovered: hoveredFavorite == favorite.id) {
                    toggleExpansion(of: box)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering { hoveredFavorite = favorite.id } else if hoveredFavorite == favorite.id { hoveredFavorite = nil }
        }
        .badge(canExpand && isExpanded ? 0 : mailbox.sidebarBadgeCount(box))
        .conversationDropTarget(box, mailbox: mailbox)
        .sidebarHover(SidebarRowSelection(source: source, mailbox: box))
        .tag(SidebarRowSelection(source: source, mailbox: box))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(favorite))
        .help(title(favorite))
        .modifier(SidebarDisclosureAccessibility(isExpanded: canExpand ? isExpanded : nil,
            badgeDescription: canExpand && isExpanded ? "" : mailbox.sidebarBadgeDescription(box),
            toggle: { toggleExpansion(of: box) }))
        .contextMenu {
            MailboxContextMenu(mailbox: mailbox, box: box, isSystemMailbox: favorite.target.isSystemMailbox)
            Divider()
            Button("Move Up", systemImage: "arrow.up") { Task { await mailbox.navigation.moveFavorite(favorite.id, by: -1) } }
                .disabled(mailbox.navigation.favorites.first?.id == favorite.id)
            Button("Move Down", systemImage: "arrow.down") { Task { await mailbox.navigation.moveFavorite(favorite.id, by: 1) } }
                .disabled(mailbox.navigation.favorites.last?.id == favorite.id)
            Button("Remove from Favorites", systemImage: "star.slash") { Task { await mailbox.navigation.removeFavorite(favorite.id) } }
        }
        if canExpand && isExpanded {
            let names = mailbox.sidebarAccountNames
            ForEach(accounts(for: box), id: \.account.id) { owner in
                let accountBox = MailboxID.account(owner.account.id, box.id)
                let name = names[owner.account.id] ?? owner.account.email
                Label {
                    Text(name)
                } icon: {
                    Image(systemName: symbol(favorite)).foregroundStyle(SidebarSymbolStyle(color: accountColor(owner.account.id)))
                }
                    .lineLimit(1).padding(.leading, Tokens.Space.s4)
                    .help(owner.account.email)
                    .badge(mailbox.sidebarBadgeCount(accountBox))
                    .conversationDropTarget(accountBox, mailbox: mailbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .sidebarHover(SidebarRowSelection(source: source, mailbox: accountBox))
                    .tag(SidebarRowSelection(source: source, mailbox: accountBox))
                    .accessibilityLabel("\(title(favorite)), \(name)")
                    .accessibilityValue(mailbox.sidebarBadgeDescription(accountBox))
                if box.id == SystemLabel.inbox { InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id, source: source) }
            }
        } else if box.id == SystemLabel.inbox, accounts(for: box).count == 1, let owner = accounts(for: box).first {
            InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id, source: source)
        }
    }

    private func toggleExpansion(of box: MailboxID) {
        if expanded.ids.contains(box.id) { expanded.ids.remove(box.id) } else { expanded.ids.insert(box.id) }
    }

    private func accounts(for box: MailboxID) -> [AccountMailbox] {
        mailbox.sidebarAccounts(for: box)
    }

    private func accountColor(_ id: String) -> Color {
        let colors = AccountAppearance.colorIndexes(for: mailbox.accounts.map(\.account.id), stored: AccountAppearance.decode(storedColors))
        return AccountAppearance.color(at: colors[id])
    }

    private func title(_ favorite: MailFavorite) -> String {
        switch favorite.target {
        case .mailbox(let label, _): return SystemMailbox(labelID: label).title
        case .label(let account, let label): return mailbox.account(id: account)?.labels.first { $0.id == label }?.title ?? "Missing Label"
        case .savedSearch(let id): return mailbox.navigation.searches.first { $0.id == id }?.name ?? "Saved Search"
        }
    }

    private func symbol(_ favorite: MailFavorite) -> String {
        switch favorite.target {
        case .mailbox(let label, _): return SystemMailbox(labelID: label).systemImage
        case .label(let account, let label):
            guard let record = mailbox.account(id: account)?.labels.first(where: { $0.id == label }) else { return "tag" }
            if record.isSystem { return SystemMailbox(labelID: label).systemImage }
            let icon = LabelAppearance.shared.icon(for: record)
            return icon == "tag" && Color(gmailHex: record.backgroundColor) != nil ? "tag.fill" : icon
        case .savedSearch: return "magnifyingglass"
        }
    }

    private func color(_ favorite: MailFavorite) -> Color {
        switch favorite.target {
        case .mailbox(let label, _): SystemMailbox(labelID: label).color
        case .label(let account, let label):
            if let record = mailbox.account(id: account)?.labels.first(where: { $0.id == label }) {
                record.isSystem ? SystemMailbox(labelID: label).color : Color(gmailHex: record.backgroundColor) ?? .secondary
            } else { .secondary }
        case .savedSearch: .secondary
        }
    }

    private func addCurrent() {
        guard let box = mailbox.selectedMailbox else { return }
        let target: MailFavoriteTarget
        if let saved = mailbox.selectedSavedSearch { target = .savedSearch(id: saved.id) }
        else {
            switch box {
            case .account(let id, let label):
                let isSystem = (SystemMailbox.all + [.outbox] + SystemMailbox.more).contains { $0.id == label }
                    || mailbox.account(id: id)?.labels.first(where: { $0.id == label })?.isSystem == true
                target = isSystem ? .mailbox(labelID: label, scope: .accounts([id])) : .label(accountID: id, labelID: label)
            case .combined(let label): target = .mailbox(labelID: label, scope: .allAccounts)
            case .scoped(let label, let ids): target = .mailbox(labelID: label, scope: .accounts(ids))
            }
        }
        Task { await mailbox.navigation.addFavorite(target) }
    }
}

/// Mark All as Read and, for Trash and Spam, emptying the mailbox. Rows in
/// the Mailboxes section add Favorites membership.
struct MailboxContextMenu: View {
    let mailbox: MailboxModel
    let box: MailboxID
    var isSystemMailbox = true
    var favoriteTarget: MailFavoriteTarget?

    var body: some View {
        if isSystemMailbox {
            Button("Mark All as Read", systemImage: "envelope.open") { mailbox.triage.markAllRead(in: box) }
                .disabled(!MailTriageModel.canMarkAllRead(box))
            if box.id == SystemLabel.trash || box.id == SystemLabel.spam {
                Button(box.id == SystemLabel.trash ? "Empty Trash…" : "Delete All Spam…", systemImage: "trash.slash", role: .destructive) {
                    mailbox.selectedMailbox = box
                    Task { await mailbox.triage.preparePermanentDeletion(entireMailbox: true) }
                }
            }
        }
        if let favoriteTarget {
            if let favorite = mailbox.navigation.favorites.first(where: { $0.target == favoriteTarget }) {
                Button("Remove from Favorites", systemImage: "star.slash") { Task { await mailbox.navigation.removeFavorite(favorite.id) } }
            } else {
                Button("Add to Favorites", systemImage: "star") { Task { await mailbox.navigation.addFavorite(favoriteTarget) } }
            }
        }
    }
}

extension MailFavoriteTarget {
    var isSystemMailbox: Bool {
        if case .mailbox = self { return true }
        return false
    }
}

struct InboxCategoryRows: View {
    let mailbox: MailboxModel
    let accountID: String
    var source: SidebarRowSelection.Source = .mailboxes
    var body: some View {
        ForEach(InboxCategory.allCases.filter { mailbox.accountPresentation[accountID]?.inboxCategories.contains($0) == true }, id: \.rawValue) { category in
            let box = SystemMailbox(labelID: category.labelID)
            Label(box.title, systemImage: box.systemImage)
                .padding(.leading, Tokens.Space.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .sidebarHover(SidebarRowSelection(source: source, mailbox: .account(accountID, category.labelID)))
                .badge(mailbox.sidebarBadgeCount(.account(accountID, category.labelID)))
                .accessibilityValue(mailbox.sidebarBadgeDescription(.account(accountID, category.labelID)))
                .tag(SidebarRowSelection(source: source, mailbox: .account(accountID, category.labelID)))
        }
    }
}
