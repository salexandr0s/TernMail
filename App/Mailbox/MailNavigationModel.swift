import Foundation
import GmailAPI
import MailStore
import Observation
import SyncEngine

@MainActor @Observable
final class MailNavigationModel {
    static let searchPrefix = "TERN_SEARCH:"
    private(set) var favorites: [MailFavorite] = MailFavorite.defaults
    private(set) var searches: [SavedMailSearch] = []
    private(set) var isSaving = false
    var error: String?
    var isShowingSwitcher = false
    var searchToEdit: SavedMailSearch?
    var isCreatingSearch = false
    var isEditingFavorites = false
    @ObservationIgnored private let store: AccountStore?

    init(store: AccountStore?) { self.store = store }

    func observe() async {
        guard let store else { return }
        do {
            for try await _ in store.mailNavigationChanges() {
                guard !Task.isCancelled else { return }
                async let favorites = store.mailFavorites()
                async let searches = store.savedMailSearches()
                let loaded = try await (favorites, searches)
                guard !Task.isCancelled else { return }
                self.favorites = loaded.0
                self.searches = loaded.1
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't read saved navigation. Try again."
        }
    }

    func saveSearch(_ search: SavedMailSearch) async -> Bool {
        await change { store in try await store.saveSavedMailSearch(search) }
    }

    func deleteSearch(_ id: String) async {
        _ = await change { try await $0.deleteSavedMailSearch(id: id) }
    }

    @discardableResult
    func addFavorite(_ target: MailFavoriteTarget) async -> Bool {
        guard !favorites.contains(where: { $0.target.matchesFavorite(target) }) else { return true }
        let updated = favorites + [MailFavorite(target: target, sortOrder: favorites.count)]
        return await change { try await $0.saveMailFavorites(updated) }
    }

    func removeFavorite(_ id: String) async {
        let updated = favorites.filter { $0.id != id }
        _ = await change { try await $0.saveMailFavorites(updated) }
    }

    func moveFavorite(_ id: String, by offset: Int) async {
        guard let index = favorites.firstIndex(where: { $0.id == id }), favorites.indices.contains(index + offset) else { return }
        var updated = favorites
        updated.swapAt(index, index + offset)
        _ = await change { try await $0.saveMailFavorites(updated) }
    }

    /// Drag reorder from the sidebar, in `onMove` terms.
    func moveFavorites(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var updated = favorites
        updated.move(fromOffsets: source, toOffset: destination)
        guard updated.map(\.id) != favorites.map(\.id) else { return }
        _ = await change { try await $0.saveMailFavorites(updated) }
    }

    func resetFavorites() async { _ = await change { try await $0.resetMailFavorites() } }

    private func change(_ operation: (AccountStore) async throws -> Void) async -> Bool {
        guard !isSaving, let store else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try await operation(store)
            favorites = try await store.mailFavorites()
            searches = try await store.savedMailSearches()
            error = nil
            return true
        } catch {
            self.error = "Couldn't save this change. Try again."
            return false
        }
    }
}

extension MailboxModel {
    var selectedSavedSearch: SavedMailSearch? {
        guard let id = selectedLabelID, id.hasPrefix(MailNavigationModel.searchPrefix) else { return nil }
        return navigation.searches.first { $0.id == String(id.dropFirst(MailNavigationModel.searchPrefix.count)) }
    }

    func openSavedSearch(_ saved: SavedMailSearch) {
        selectedMailbox = .combined(MailNavigationModel.searchPrefix + saved.id)
        activateSavedSearch(saved)
    }

    func refreshSavedSearch() {
        guard selectedLabelID?.hasPrefix(MailNavigationModel.searchPrefix) == true else { return }
        guard let saved = selectedSavedSearch else {
            if presentedAccounts.count == 1, let first = presentedAccounts.first {
                selectedMailbox = .account(first.account.id, SystemLabel.inbox)
            } else { selectedMailbox = .combined(SystemLabel.inbox) }
            return
        }
        activateSavedSearch(saved)
    }

    private func activateSavedSearch(_ saved: SavedMailSearch) {
        var ids: Set<String>
        switch saved.scope {
        case .allAccounts: ids = Set(presentedAccounts.map(\.account.id))
        case .accounts(let selected): ids = Set(selected).intersection(presentedAccounts.map(\.account.id))
        }
        if case .account(let accountID, _)? = selectedMailbox { ids.formIntersection([accountID]) }
        if case .scoped(_, let selected)? = selectedMailbox { ids.formIntersection(selected) }
        search.setSources(presentedAccounts.filter { ids.contains($0.account.id) }.map { .init(accountID: $0.account.id, engine: $0.engine) })
        search.update(saved.query)
        search.submit()
    }

    func favoriteMailboxID(_ target: MailFavoriteTarget) -> MailboxID? {
        switch target {
        case .mailbox(let label, let scope):
            switch scope {
            case .allAccounts:
                let visible = presentedAccounts
                guard let first = visible.first else { return nil }
                return visible.count > 1 ? .combined(label) : .account(first.account.id, label)
            case .accounts(let ids):
                let visible = Array(Set(ids).intersection(presentedAccounts.map(\.account.id))).sorted()
                guard !visible.isEmpty else { return nil }
                return visible.count == 1 ? .account(visible[0], label) : .scoped(label, visible)
            }
        case .label(let accountID, let labelID):
            guard presentedAccounts.contains(where: { $0.account.id == accountID }) else { return nil }
            return .account(accountID, labelID)
        case .savedSearch(let id):
            guard let search = navigation.searches.first(where: { $0.id == id }) else { return nil }
            switch search.scope {
            case .allAccounts: return .combined(MailNavigationModel.searchPrefix + id)
            case .accounts(let ids):
                let visible = Array(Set(ids).intersection(presentedAccounts.map(\.account.id))).sorted()
                return visible.isEmpty ? nil : .scoped(MailNavigationModel.searchPrefix + id, visible)
            }
        }
    }

    /// A sidebar row's number: the Outbox's messages, otherwise unread conversations.
    func sidebarBadgeCount(_ box: MailboxID) -> Int {
        let owners: [AccountMailbox]
        switch box {
        case .combined: owners = presentedAccounts
        case .account(let id, _): owners = presentedAccounts.filter { $0.account.id == id }
        case .scoped(_, let ids): owners = presentedAccounts.filter { ids.contains($0.account.id) }
        }
        if box.id == Self.outboxID { return owners.reduce(0) { $0 + $1.outbox.count } }
        return owners.reduce(0) { sum, owner in
            let label = owner.labels.first { $0.id == box.id }
            if box.id == SystemLabel.starred, listPreferences.starredTotal { return sum + (label?.messagesTotal ?? label?.threadsTotal ?? 0) }
            if box.id == SystemLabel.draft, listPreferences.draftsTotal { return sum + (label?.messagesTotal ?? label?.threadsTotal ?? 0) }
            if box.id == SystemLabel.spam, !listPreferences.spamUnread { return sum }
            return sum + (label?.messagesUnread ?? label?.threadsUnread ?? 0)
        }
    }

    func isVisibleInSidebar(_ label: LabelRecord) -> Bool {
        switch label.labelListVisibility {
        case "labelHide": return false
        case "labelShowIfUnread": return (label.messagesUnread ?? label.threadsUnread ?? 0) > 0
        default: return true
        }
    }

    func setLabelVisibility(_ label: LabelRecord, to visibility: LabelListVisibility) {
        guard let owner = account(id: label.accountID) else { return }
        queueUndoable("Change Label Visibility", in: owner) { try await $0.setLabelVisibility(label.id, to: visibility) }
    }

    func setCategory(_ category: InboxCategory, enabled: Bool, accountID: String) async {
        guard let accountStore else { return }
        do {
            let updated = try await accountStore.updateMailPreferences(accountID: accountID) { preferences in
                if enabled { preferences.inboxCategories.insert(category) } else { preferences.inboxCategories.remove(category) }
            }
            accountPresentation[accountID] = updated
        } catch { notice = Notice(message: "Couldn't save Inbox categories.", isError: true) }
    }
}

extension MailFavoriteTarget {
    /// Older account-folder shortcuts use the label form for system folders.
    /// Unified folders retain their distinct scope, including with one account.
    func matchesFavorite(_ other: MailFavoriteTarget) -> Bool {
        if self == other { return true }
        switch (self, other) {
        case let (.label(accountID, labelID), .mailbox(otherLabelID, .accounts(accountIDs))),
             let (.mailbox(otherLabelID, .accounts(accountIDs)), .label(accountID, labelID)):
            return labelID == otherLabelID && accountIDs == [accountID]
        default:
            return false
        }
    }
}
