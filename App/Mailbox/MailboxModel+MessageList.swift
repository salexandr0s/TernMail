import Foundation
import MailStore
import MessageContent
import SyncEngine

extension MailboxModel {
    var presentedAccounts: [AccountMailbox] {
        accounts.filter { visibleAccountIDs?.contains($0.account.id) ?? true }.sorted { lhs, rhs in
            let left = accountPresentation[lhs.account.id]?.sortOrder ?? 0
            let right = accountPresentation[rhs.account.id]?.sortOrder ?? 0
            return left == right ? lhs.account.addedAt < rhs.account.addedAt : left < right
        }
    }

    func accountTitle(_ account: AccountRecord) -> String {
        let nickname = accountPresentation[account.id]?.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        return nickname?.isEmpty == false ? nickname ?? account.email : account.email
    }

    var listItems: [MessageListItem] {
        let categories = accountPresentation.mapValues { preferences in
            Set(preferences.inboxCategories.map { "CATEGORY_" + $0.rawValue.uppercased() })
        }
        var addresses = listOwnAddresses
        for account in accounts { addresses[account.account.id, default: []].insert(account.account.email.lowercased()) }
        return listProjection.items(for: .init(threads: listedThreads, entries: listEntries,
            conversations: listPreferences.conversations, filters: listPreferences.filters,
            mailboxID: search.isActive ? nil : selectedLabelID, categories: categories, addresses: addresses))
    }

    var selectedListRowIDs: Set<MailListRowID> {
        if listPreferences.conversations {
            return Set(selectedThreadIDs.map { .init(accountID: $0.accountID, threadID: $0.threadID) })
        }
        return selectedMessageRows
    }

    func selectListRows(_ rows: Set<MailListRowID>) {
        let valid = rows.intersection(Set(listItems.map(\.id)))
        selectedMessageRows = listPreferences.conversations ? [] : valid
        selectedThreadIDs = Set(valid.map(\.threadKey))
    }

    /// What a row stands for: its conversation, or its one message in message mode.
    func conversationLink(for row: MailListRowID) -> MailLink {
        MailLink(accountID: row.accountID, threadID: row.threadID, messageID: listPreferences.conversations ? nil : row.messageID)
    }

    func requestConversationWindow(for row: MailListRowID) {
        conversationWindowRequest = conversationLink(for: row)
    }

    /// This snapshot is shared by triage, commands and the message list.
    var selectedActionTargets: [(accountID: String, target: MailActionTarget)] {
        actionTargets(forRows: selectedListRowIDs)
    }

    func actionTargets(for ids: Set<ThreadKey>) -> [(accountID: String, target: MailActionTarget)] {
        if listPreferences.conversations {
            return actionTargets(forRows: Set(ids.map { .init(accountID: $0.accountID, threadID: $0.threadID) }))
        }
        return actionTargets(forRows: selectedMessageRows.filter { ids.contains($0.threadKey) })
    }

    func actionTargets(forRows rows: Set<MailListRowID>) -> [(accountID: String, target: MailActionTarget)] {
        Dictionary(grouping: rows, by: \.accountID).sorted { $0.key < $1.key }.compactMap { accountID, rows in
            guard account(id: accountID) != nil else { return nil }
            let messages = rows.compactMap(\.messageID).sorted()
            if messages.count == rows.count { return (accountID, .messages(messages)) }
            // A mixed identity set is invalid. Never widen message authority.
            guard messages.isEmpty else { return nil }
            return (accountID, .threads(Array(Set(rows.map(\.threadID))).sorted()))
        }
    }

    @discardableResult
    func performListAction(_ action: MailAction, rows: Set<MailListRowID>) -> Task<Void, Never>? {
        let targets = actionTargets(forRows: rows)
        guard !targets.isEmpty else { return nil }
        let keys = Set(rows.map(\.threadKey))
        if !search.isActive, action == .trash || (action == .archive && selectedLabelID == SystemLabel.inbox) {
            selectRow(after: rows)
        }
        return queueUndoable(actionName(action), for: keys, sound: MailSounds.event(for: action)) { owner, _ in
            guard let target = targets.first(where: { $0.accountID == owner.account.id })?.target else { return nil }
            return try await owner.engine.perform(action, target: target)
        }
    }

    /// Menus title the toggle by these: one unread row offers Mark as Read.
    func allListRead(_ rows: Set<MailListRowID>) -> Bool {
        !listItems.contains { rows.contains($0.id) && $0.thread.isUnread }
    }

    func allListStarred(_ rows: Set<MailListRowID>) -> Bool {
        let selected = listItems.filter { rows.contains($0.id) }
        return !selected.isEmpty && selected.allSatisfy { $0.thread.isStarred }
    }

    func toggleListRead(_ rows: Set<MailListRowID>) {
        performListAction(allListRead(rows) ? .markUnread : .markRead, rows: rows)
    }

    func toggleListStar(_ rows: Set<MailListRowID>) {
        performListAction(allListStarred(rows) ? .unstar : .star, rows: rows)
    }

    func selectRow(after leaving: Set<MailListRowID>) {
        guard leaving == selectedListRowIDs else { return }
        let rows = listItems.map(\.id)
        guard let first = rows.firstIndex(where: leaving.contains), let last = rows.lastIndex(where: leaving.contains) else { return }
        let above = rows[..<first].last { !leaving.contains($0) }
        let below = rows[(last + 1)...].first { !leaving.contains($0) }
        let next: MailListRowID?
        switch listPreferences.nextSelection {
        case .below: next = below ?? above
        case .above: next = above ?? below
        case .none: next = nil
        }
        selectListRows(next.map { [$0] } ?? [])
    }

    func searchFromAddress(_ address: String, accountID: String) { searchAddress(address, accountID: accountID, field: "from") }
    func searchToAddress(_ address: String, accountID: String) { searchAddress(address, accountID: accountID, field: "to") }

    private func searchAddress(_ address: String, accountID: String, field: String) {
        guard let address = EmailAddress.parseList(address).first, address.isValid else { return }
        selectedMailbox = .account(accountID, SystemLabel.allMail)
        let escaped = address.address.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        search.update("\(field):\"\(escaped)\"")
        search.submit()
    }

    private func actionName(_ action: MailAction) -> String {
        switch action {
        case .archive: "Archive"
        case .trash: "Move to Trash"
        case .markRead: "Mark as Read"
        case .markUnread: "Mark as Unread"
        case .star: "Star"
        case .unstar: "Remove Star"
        }
    }
}
