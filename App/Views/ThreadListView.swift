import MailStore
import MessageContent
import QuickLook
import SwiftUI

struct ThreadListView: View {
    @Bindable var mailbox: MailboxModel
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()
    @Environment(\.openWindow) private var openWindow
    @FocusState private var listFocused: Bool
    @Namespace private var dragNamespace
    @State private var previewURL: URL?

    var body: some View {
        list
            .modifier(MessagePrefetchModifier(mailbox: mailbox))
            .overlay {
                if mailbox.listItems.isEmpty {
                    if mailbox.search.isActive {
                        emptySearch
                    } else {
                        emptyMailbox
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                MessageListHeader(mailbox: mailbox)
                if mailbox.showsSnoozed {
                    Label("Snoozed on this Mac", systemImage: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Space.s3)
                        .padding(.vertical, Tokens.Space.s2)
                        .background(.bar)
                        .help("Snoozes stay on this Mac and don't show in Gmail or on other devices.")
                }
            }
            .onChange(of: mailbox.search.listFocusRequest) {
                listFocused = mailbox.selectedLabelID != MailboxModel.outboxID || mailbox.search.isActive
            }
            .task(id: observationID) {
                await observeEntries(for: displayedThreads.map(\.key))
            }
            .task(id: mailbox.accounts.map(\.account.id)) { await observeAddresses() }
            .onChange(of: mailbox.listPreferences.conversations) { _, _ in
                mailbox.search.setMessageMode(!mailbox.listPreferences.conversations)
                mailbox.selectedMessageRows = []
                mailbox.selectedThreadIDs = []
            }
            .onChange(of: mailbox.listItems.map(\.id)) { _, ids in
                mailbox.selectListRows(mailbox.selectedListRowIDs.intersection(ids))
            }
    }

    /// Choose Date & Time opens beside the first conversation it will snooze.
    private func snoozeDateAnchor(in rows: [MessageListItem]) -> MailListRowID? {
        guard let keys = mailbox.snoozeDateTargets else { return nil }
        let targetRows = mailbox.snoozeRowTargets
        return rows.first { targetRows?.contains($0.id) ?? keys.contains($0.id.threadKey) }?.id
    }

    @ViewBuilder private var snoozeDatePicker: some View {
        if let ids = mailbox.snoozeDateTargets {
            SnoozeDateSheet(
                initial: SnoozeSchedule().wakeTime(for: .tomorrow, now: .now) ?? .now.addingTimeInterval(3600),
                now: .now,
                onSnooze: { mailbox.snooze(ids, until: $0) },
                onCancel: { mailbox.snoozeDateTargets = nil }
            )
        }
    }

    /// Double-click and Return open each chosen conversation in its own window, in list order.
    private func openConversations(_ ids: Set<MailListRowID>) {
        for row in mailbox.listItems where ids.contains(row.id) {
            openWindow(id: ConversationWindow.sceneID, value: mailbox.conversationLink(for: row.id))
        }
    }

    /// Space previews the one selected conversation's first attachment, and
    /// otherwise toggles the selection between read and unread.
    private func previewOrToggleRead() -> KeyPress.Result {
        let selection = mailbox.selectedListRowIDs
        guard !selection.isEmpty else { return .ignored }
        if selection.count == 1, let item = mailbox.listItems.first(where: { selection.contains($0.id) }),
           let attachment = item.attachments.first {
            Task { previewURL = await mailbox.download(attachment) }
        } else {
            mailbox.toggleListRead(selection)
        }
        return .handled
    }

    private var displayedThreads: [ThreadRecord] {
        mailbox.search.isActive ? mailbox.search.results : mailbox.threads
    }

    private var observationID: MessageListObservationID {
        .init(keys: displayedThreads.map(\.key), query: mailbox.search.queryText,
              remoteRevision: mailbox.search.gmail?.revision ?? 0, conversations: mailbox.listPreferences.conversations)
    }

    private func observeEntries(for keys: [ThreadKey]) async {
        guard !Task.isCancelled else { return }
        let visible = Set(keys)
        mailbox.listEntries = mailbox.listEntries.filter { visible.contains(ThreadKey(accountID: $0.message.accountID, threadID: $0.message.threadID)) }
        guard !keys.isEmpty else { mailbox.listEntries = []; return }
        let threadsByAccount = Dictionary(grouping: keys, by: \.accountID).mapValues { $0.map(\.threadID) }
        do {
            let query = mailbox.search.isActive && !mailbox.listPreferences.conversations ? mailbox.search.query : nil
            for try await entries in mailbox.cache.messageListEntries(threadsByAccount: threadsByAccount, matching: query,
                                                                      includingMessageIDs: mailbox.search.matchingMessageIDs, snoozedOnly: mailbox.showsSnoozed) {
                guard !Task.isCancelled else { return }
                mailbox.listEntries = entries
                if mailbox.listItems.isEmpty { mailbox.loadMoreThreads() }
            }
        } catch {
            guard !Task.isCancelled else { return }
            mailbox.listEntries = []
        }
    }

    private func observeAddresses() async {
        guard let store = mailbox.accountStore else { return }
        do {
            for try await identities in store.listIdentityChanges(accountIDs: mailbox.accounts.map(\.account.id)) {
                guard !Task.isCancelled else { return }
                mailbox.listOwnAddresses = Dictionary(grouping: identities.filter(\.canSend), by: \.accountID)
                    .mapValues { Set($0.map(\.lowercasedAddress)) }
            }
        } catch {
            guard !Task.isCancelled else { return }
            mailbox.listOwnAddresses = [:]
        }
    }

    @ViewBuilder
    private var emptyMailbox: some View {
        if !mailbox.listPreferences.filters.isEmpty {
            VStack(spacing: Tokens.Space.s3) {
                TernEmptyState(title: "No Matching Mail", systemImage: "line.3.horizontal.decrease.circle", message: "Try different filters or clear them to see all mail.", fillsSpace: false)
                Button("Clear Filters") { mailbox.listPreferences.filters = [] }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mailbox.selectedHaveSyncedOnce {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "No Conversations", systemImage: "tray", message: emptyDescription, fillsSpace: false)
                if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, action: mailbox.loadOlderConversations)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .failed(let message) = mailbox.selectedSyncStatus {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "Can't Download Mail", systemImage: "wifi.exclamationmark", message: message, fillsSpace: false)
                Button("Try Again") { mailbox.syncNow() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView {
                Text("Downloading mail…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptySearch: some View {
        let search = mailbox.search
        switch search.status {
        case .unreadable:
            TernEmptyState(
                title: "Can't Search",
                systemImage: "exclamationmark.magnifyingglass",
                message: "Tern couldn't read the mail saved on this Mac."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .searching:
            ProgressView {
                Text(search.gmailState == .loading ? "Searching Gmail…" : "Searching…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .searchedThisMac, .searchedEverywhere:
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(
                    title: "No Results",
                    systemImage: "magnifyingglass",
                    message: search.status == .searchedEverywhere
                        ? "No matches on this Mac or in Gmail."
                        : "No matches on this Mac.",
                    fillsSpace: false
                )
                if search.status == .searchedThisMac {
                    GmailRow(kind: .search, state: search.gmailState, action: search.askGmail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Keep the native scroll view mounted while mailbox and search states change.
    private var list: some View {
        let rows = mailbox.listItems
        let selection = mailbox.selectedListRowIDs
        let isSearching = mailbox.search.isActive
        let accountMarks = compactAccountMarks
        let accountColors = AccountAppearance.colorIndexes(
            for: mailbox.accounts.map(\.account.id), stored: AccountAppearance.decode(storedColors)
        )
        let snoozeAnchor = snoozeDateAnchor(in: rows)
        return List(selection: $mailbox.selectedListRowIDs) {
            // Keyed by account too, since thread IDs repeat across accounts.
            ForEach(rows) { row in
                MessageListRow(
                    item: row, mailbox: mailbox, isSelected: selection.contains(row.id),
                    accountMark: accountMarks[row.id.accountID], accountColor: AccountAppearance.color(at: accountColors[row.id.accountID])
                )
                    .tag(row.id)
                    .draggable(containerItemID: row.id, containerNamespace: dragNamespace)
                    // Only the first targeted row anchors the snooze popover.
                    .popover(isPresented: snoozeAnchor == row.id ? $mailbox.snoozeDateTargets.isPresent() : .constant(false),
                             arrowEdge: .trailing) { snoozeDatePicker }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        swipeButtons(first: mailbox.listPreferences.leadingFirst, second: mailbox.listPreferences.leadingSecond, row: row)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        swipeButtons(first: mailbox.listPreferences.trailingFirst, second: mailbox.listPreferences.trailingSecond, row: row)
                    }
                    .onAppear {
                        if row.id == rows.last?.id {
                            if isSearching {
                                mailbox.search.loadMoreResults()
                            } else {
                                mailbox.loadMoreThreads()
                            }
                        }
                    }
            }
            // Restart row appearance and pagination when entering or leaving search.
            .id(isSearching)
            // Apply outside the row wrappers so the native list receives these insets.
            // The column's resize gutter stays outside the list.
            .listRowInsets(.horizontal, -Tokens.Space.s2)
            if !rows.isEmpty {
                if isSearching {
                    let gmail = mailbox.search.gmailState
                    if gmail != .finished {
                        GmailRow(kind: .search, state: gmail, action: mailbox.search.askGmail)
                    }
                } else if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, action: mailbox.loadOlderConversations)
                }
            }
        }
        .listStyle(.inset)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.top, Tokens.Space.s2, for: .scrollContent)
        // Dragging a selected row carries the whole selection.
        .dragContainer(for: ConversationDragItem.self, itemID: \.rowID, in: dragNamespace) { ids in
            ids.map { ConversationDragItem(mailbox.conversationLink(for: $0)) }
        }
        .dragContainerSelection(Array(selection), containerNamespace: dragNamespace)
        .contextMenu(forSelectionType: MailListRowID.self) { ids in
            MessageListMenu(mailbox: mailbox, rows: ids)
        } primaryAction: { ids in
            openConversations(ids)
        }
        .onDeleteCommand { mailbox.performDeleteKeyAction() }
        .onKeyPress(.return) {
            guard !mailbox.selectedListRowIDs.isEmpty else { return .ignored }
            openConversations(mailbox.selectedListRowIDs)
            return .handled
        }
        .onKeyPress(.space) { previewOrToggleRead() }
        .quickLookPreview($previewURL)
        .protectAttachmentPreview(previewURL)
        .focused($listFocused)
    }

    @ViewBuilder private func swipeButtons(first: MailSwipeAction, second: MailSwipeAction, row: MessageListItem) -> some View {
        swipeButton(first, row: row)
        swipeButton(second, row: row)
    }

    @ViewBuilder private func swipeButton(_ action: MailSwipeAction, row: MessageListItem) -> some View {
        if action != .none {
            let title = action.buttonTitle(isUnread: row.thread.isUnread, isStarred: row.thread.isStarred)
            Button { mailbox.performSwipe(action, on: row.id) } label: { Label(title, systemImage: action.symbol) }
                .tint(action == .trash || action == .spam ? .red : .accentColor)
                .disabled((action == .archive && !mailbox.offersArchive) || (action == .trash && !mailbox.offersTrash)
                          || (action == .snooze && !mailbox.offersArchive))
        }
    }

    /// Use all accounts so a badge keeps its meaning when the list is filtered.
    private var compactAccountMarks: [String: String] {
        let groups = Dictionary(grouping: mailbox.accounts.map(\.account)) { account in
            let localPart = account.email.prefix { $0 != "@" }
            return localPart.isEmpty ? "?" : String(localPart.prefix(2)).uppercased()
        }
        var marks: [String: String] = [:]
        for (initials, accounts) in groups {
            for (index, account) in accounts.enumerated() {
                marks[account.id] = accounts.count > 1 ? "\(initials)·\(index + 1)" : initials
            }
        }
        return marks
    }

    private var emptyDescription: String {
        if mailbox.selectedLabelID == SystemLabel.inbox { return "Your inbox is empty." }
        if mailbox.showsSnoozed { return "Snoozed conversations wait here until they return to the Inbox." }
        return "Tern keeps your inbox and the last 30 days of mail on this Mac."
    }
}

/// The end of a list that Gmail can add to: a button, progress, or why
/// Gmail didn't answer.
private struct GmailRow: View {
    enum Kind {
        case search
        case older
    }

    let kind: Kind
    let state: GmailPager.State
    let action: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Space.s2) {
            switch state {
            case .ready, .more:
                Button(action: action) {
                    Label(buttonTitle, systemImage: kind == .search ? "magnifyingglass" : "arrow.down")
                }
                .buttonStyle(.bordered)
            case .loading:
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text(kind == .search ? "Searching Gmail…" : "Loading older conversations…")
                        .foregroundStyle(.secondary)
                }
            case .busy, .failed:
                Text(failure)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: action)
                    .buttonStyle(.bordered)
            case .finished:
                EmptyView()
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(Tokens.Space.s3)
    }

    private var buttonTitle: String {
        switch (kind, state) {
        case (.search, .ready): "Search Gmail"
        case (.search, _): "Load More from Gmail"
        case (.older, _): "Load Older Conversations"
        }
    }

    private var failure: String {
        switch (kind, state) {
        case (.search, .busy): "Gmail is busy. Showing results from this Mac only."
        case (.search, _): "Couldn't reach Gmail. Showing results from this Mac only."
        case (.older, .busy): "Gmail is busy. Try again in a moment."
        case (.older, _): "Couldn't reach Gmail. Check your connection."
        }
    }
}

enum ThreadDate {
    /// Time for today, month and day for this year, otherwise the numeric date.
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// When a snooze ends: "Oct 30, 8:00 AM".
    static func wake(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
