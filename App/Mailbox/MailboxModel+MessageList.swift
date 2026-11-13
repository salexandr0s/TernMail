import Foundation
import MailStore
import MessageContent
import Observation
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

    /// Loading the next page starts once a row this close to the end appears,
    /// so more rows are ready before the user reaches the last one.
    static let paginationLead = 40

    var listItems: [MessageListItem] {
        let key = listProjectionKey
        if let rows = listProjection.cached(for: key) { return rows }
        // Direct preference edits and model-only callers stay synchronous.
        // Database snapshots are normally prepared off-main before publication.
        let rows = MessageListProjection.prepare(listProjectionInput(threads: listedThreads, entries: listEntries, mailboxID: key.mailboxID))
        listProjection.store(rows, for: key)
        return rows
    }

    /// One projection's rows: their IDs in order and as a set, and each row's state.
    struct ListRowIndex {
        let key: MessageListProjection.Key
        let ordered: [MailListRowID]
        let set: Set<MailListRowID>
        let states: [MessageListRowState]
    }

    /// Row IDs in list order. Selection and keyboard navigation read these
    /// rather than mapping every row again.
    var listRowIDs: [MailListRowID] { currentListRowIndex.ordered }
    var listRowIDSet: Set<MailListRowID> { currentListRowIndex.set }
    /// The list's rows in order. A page with the same rows in the same order
    /// returns the same objects, and only the rows that changed are written to.
    var listRowStates: [MessageListRowState] { currentListRowIndex.states }

    private var currentListRowIndex: ListRowIndex {
        let key = listProjectionKey
        if let index = listRowIndex, index.key == key { return index }
        let items = listItems
        let index: ListRowIndex
        if let previous = listRowIndex, previous.ordered.elementsEqual(items.lazy.map(\.id)) {
            index = ListRowIndex(key: key, ordered: previous.ordered, set: previous.set, states: previous.states)
        } else {
            // A row that stays keeps its state object, so its view stays too.
            var known = Dictionary((listRowIndex?.states ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ordered = items.map(\.id)
            let states = items.map { known.removeValue(forKey: $0.id) ?? MessageListRowState(item: $0) }
            index = ListRowIndex(key: key, ordered: ordered, set: Set(ordered), states: states)
        }
        // Native separators belong to the preceding row's bottom edge.
        for (offset, item) in items.enumerated() {
            let nextIsUnread = offset + 1 < items.count && items[offset + 1].thread.isUnread
            index.states[offset].update(item: item, hidesSeparator: item.thread.isUnread || nextIsUnread)
        }
        listRowIndex = index
        return index
    }

    var listProjectionKey: MessageListProjection.Key {
        .init(dataRevision: listDataRevision, contextRevision: listContextRevision,
              conversations: listPreferences.conversations, filters: listPreferences.filters,
              mailboxID: search.isActive ? nil : selectedLabelID, retainedUnreadRows: retainedUnreadReadingRows)
    }

    func listProjectionConfiguration(mailboxID: String?) -> MessageListProjection.Key {
        .init(dataRevision: 0, contextRevision: listContextRevision,
              conversations: listPreferences.conversations, filters: listPreferences.filters, mailboxID: mailboxID,
              retainedUnreadRows: retainedUnreadReadingRows)
    }

    func listProjectionInput(threads: [ThreadRecord], entries: [MessageListEntry], mailboxID: String?) -> MessageListProjection.Input {
        let categories = accountPresentation.mapValues { preferences in
            Set(preferences.inboxCategories.map { "CATEGORY_" + $0.rawValue.uppercased() })
        }
        var addresses = listOwnAddresses
        for account in accounts { addresses[account.account.id, default: []].insert(account.account.email.lowercased()) }
        return .init(threads: threads, entries: entries,
            conversations: listPreferences.conversations, filters: listPreferences.filters,
            mailboxID: mailboxID, categories: categories, addresses: addresses,
            availableLabels: Dictionary(accounts.map { ($0.account.id, $0.listLabels) }, uniquingKeysWith: { first, _ in first }),
            retainedUnreadRows: retainedUnreadReadingRows)
    }

    /// The list's selection. Setting it keeps only rows the list shows.
    var selectedListRowIDs: Set<MailListRowID> {
        get {
            if listPreferences.conversations {
                return Set(selectedThreadIDs.map { .init(accountID: $0.accountID, threadID: $0.threadID) })
            }
            return selectedMessageRows
        }
        set { selectListRows(newValue) }
    }

    func selectListRows(_ rows: Set<MailListRowID>) {
        let listed = listRowIDSet
        let valid = rows.filter { listed.contains($0) }
        let messages = listPreferences.conversations ? [] : valid
        let threads = Set(valid.map(\.threadKey))
        if selectedMessageRows != messages { selectedMessageRows = messages }
        if selectedThreadIDs != threads { selectedThreadIDs = threads }
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
        // Row menus, swipes and message mode confirm with Undo like the toolbar does.
        let confirmation = Self.confirmation(action, count: rows.count, messages: rows.allSatisfy { $0.messageID != nil })
        return queueUndoable(Self.undoName(action), confirmation: confirmation, for: keys, sound: MailSounds.event(for: action)) { owner, _ in
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
        let rows = listRowIDs
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
        guard let address = EmailAddress.parseList(address).first, address.isValid,
              let operand = SearchQuery.quoted(address.address) else { return }
        selectedMailbox = .account(accountID, SystemLabel.allMail)
        search.update("\(field):" + operand)
        search.submit()
    }

    var currentMailboxMessageCount: Int {
        selectedAccounts.reduce(0) { total, owner in
            let label = owner.labels.first { $0.id == selectedLabelID }
            return total + (label?.messagesTotal ?? label?.threadsTotal ?? listEntries.filter { $0.message.accountID == owner.account.id }.count)
        }
    }

    func performSwipe(_ action: MailSwipeAction, on row: MailListRowID) {
        switch action {
        case .archive: performListAction(.archive, rows: [row])
        case .trash: performListAction(.trash, rows: [row])
        case .read: toggleListRead([row])
        case .star: toggleListStar([row])
        case .move: showMoveTo(forRows: [row])
        case .label: showEditLabels(forRows: [row])
        case .spam: triage.perform(.spam, targets: actionTargets(forRows: [row]))
        case .snooze:
            showSnoozeDate(forRows: [row])
        case .none: break
        }
    }
}

/// One list row's content. Each row's view observes its own state, so a page
/// that changes one conversation updates that row and leaves the others alone.
@MainActor
@Observable
final class MessageListRowState: Identifiable {
    nonisolated let id: MailListRowID
    private(set) var item: MessageListItem
    /// Whether the line under this row is hidden: the row or the one after it is unread.
    private(set) var hidesSeparator = false

    init(item: MessageListItem) {
        id = item.id
        self.item = item
    }

    /// Writes only what differs, so an unchanged row's view isn't asked to update.
    fileprivate func update(item: MessageListItem, hidesSeparator: Bool) {
        if self.item != item { self.item = item }
        if self.hidesSeparator != hidesSeparator { self.hidesSeparator = hidesSeparator }
    }
}
