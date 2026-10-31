import MailStore
import SwiftUI

struct FavoritesView: View {
    let mailbox: MailboxModel
    @AppStorage(SidebarView.expandedKey) private var expanded = SystemLabel.inbox
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()

    var body: some View {
        Section {
            ForEach(mailbox.navigation.favorites) { favorite in
                if let box = mailbox.favoriteMailboxID(favorite.target) {
                    favoriteRows(favorite, box: box)
                }
            }
            .onMove { source, destination in
                Task { await mailbox.navigation.moveFavorites(fromOffsets: source, toOffset: destination) }
            }
        } header: {
            HStack {
                Text("Favorites")
                Spacer()
                Menu {
                    Button("Add Current Mailbox") { addCurrent() }
                        .disabled(mailbox.selectedLabelID == nil || mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID)
                    Button("New Saved Search…") { mailbox.navigation.isCreatingSearch = true }
                    Divider()
                    Button("Reset Favorites") { Task { await mailbox.navigation.resetFavorites() } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Edit Favorites")
            }
        }
    }

    @ViewBuilder private func favoriteRows(_ favorite: MailFavorite, box: MailboxID) -> some View {
        let isExpanded = expanded.split(separator: ",").contains { $0 == box.id }
        let canExpand = accounts(for: box).count > 1
        HStack(spacing: Tokens.Space.s1) {
            if canExpand { Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary) }
            Label(title(favorite), systemImage: symbol(favorite)).lineLimit(1)
        }
        .badge(canExpand && isExpanded ? 0 : mailbox.sidebarBadgeCount(box))
        .tag(box)
        .onTapGesture {
            mailbox.selectedMailbox = box
            if canExpand {
                var ids = Set(expanded.split(separator: ",").map(String.init))
                if isExpanded { ids.remove(box.id) } else { ids.insert(box.id) }
                expanded = ids.sorted().joined(separator: ",")
            }
        }
        .accessibilityLabel(title(favorite))
        .accessibilityValue(canExpand ? (isExpanded ? "Expanded" : "Collapsed") : "")
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
            ForEach(accounts(for: box), id: \.account.id) { owner in
                let accountBox = MailboxID.account(owner.account.id, box.id)
                Label {
                    Text(shortName(owner.account))
                } icon: {
                    Image(systemName: symbol(favorite)).foregroundStyle(accountColor(owner.account.id))
                }
                    .lineLimit(1).padding(.leading, Tokens.Space.s8)
                    .badge(mailbox.sidebarBadgeCount(accountBox)).tag(accountBox)
                    .accessibilityLabel("\(title(favorite)), \(shortName(owner.account))")
                if box.id == SystemLabel.inbox { InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id) }
            }
        } else if box.id == SystemLabel.inbox, accounts(for: box).count == 1, let owner = accounts(for: box).first {
            InboxCategoryRows(mailbox: mailbox, accountID: owner.account.id)
        }
    }

    private func accounts(for box: MailboxID) -> [AccountMailbox] {
        switch box {
        case .combined: mailbox.presentedAccounts
        case .account(let id, _): mailbox.presentedAccounts.filter { $0.account.id == id }
        case .scoped(_, let ids): mailbox.presentedAccounts.filter { ids.contains($0.account.id) }
        }
    }

    private func shortName(_ account: AccountRecord) -> String {
        if let nickname = mailbox.accountPresentation[account.id]?.nickname, !nickname.isEmpty { return nickname }
        return AccountAppearance.shortNames(mailbox.accounts.map(\.account))[account.id] ?? account.email
    }

    private func accountColor(_ id: String) -> Color {
        let colors = AccountAppearance.colorIndexes(for: mailbox.accounts.map(\.account.id), stored: AccountAppearance.decode(storedColors))
        return AccountAppearance.color(at: colors[id])
    }

    private func title(_ favorite: MailFavorite) -> String {
        switch favorite.target {
        case .mailbox(let label, _): return SystemMailbox.all.first { $0.id == label }?.title ?? label
        case .label(let account, let label): return mailbox.account(id: account)?.labels.first { $0.id == label }?.name ?? "Missing Label"
        case .savedSearch(let id): return mailbox.navigation.searches.first { $0.id == id }?.name ?? "Saved Search"
        }
    }

    private func symbol(_ favorite: MailFavorite) -> String {
        switch favorite.target {
        case .mailbox(let label, _): SystemMailbox.all.first { $0.id == label }?.systemImage ?? "tray"
        case .label: "tag"
        case .savedSearch: "magnifyingglass"
        }
    }

    private func addCurrent() {
        guard let box = mailbox.selectedMailbox else { return }
        let target: MailFavoriteTarget
        if let saved = mailbox.selectedSavedSearch { target = .savedSearch(id: saved.id) }
        else {
            switch box {
            case .account(let id, let label):
                target = SystemMailbox.all.contains { $0.id == label } ? .mailbox(labelID: label, scope: .accounts([id])) : .label(accountID: id, labelID: label)
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
    var body: some View {
        ForEach(InboxCategory.allCases.filter { mailbox.accountPresentation[accountID]?.inboxCategories.contains($0) == true }, id: \.rawValue) { category in
            Label(category.rawValue.capitalized, systemImage: "tray.full")
                .padding(.leading, Tokens.Space.s12)
                .badge(mailbox.sidebarBadgeCount(.account(accountID, category.labelID)))
                .tag(MailboxID.account(accountID, category.labelID))
        }
    }
}
