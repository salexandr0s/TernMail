import MailStore
import MessageContent
import QuickLook
import SwiftUI

struct ThreadListView: View {
    let mailbox: MailboxModel
    @Environment(\.openWindow) private var openWindow
    /// Read only as a key comes, so a switch of section doesn't build the list again.
    @Environment(AppModel.self) private var app
    @FocusState private var listFocused: Bool
    @Namespace private var dragNamespace
    @State private var previewURL: URL?

    #if TERN_TEST_SUPPORT || TERN_PERFORMANCE
    /// Scoped by the test to its mailbox; measures row construction, not projection reuse.
    static var onRowContentBuild: ((MailboxModel, MailListRowID) -> Void)?
    /// Counts each run of a row host's body, the part that follows one row's content.
    static var onRowHostBuild: ((MailboxModel, MailListRowID) -> Void)?
    #endif
    #if TERN_TEST_SUPPORT
    enum BodyPhase { case list, dragSelection }
    static var onBodyBuild: ((MailboxModel, BodyPhase) -> Void)?
    #endif

    var body: some View {
        #if TERN_TEST_SUPPORT
        let _ = Self.onBodyBuild?(mailbox, .list)
        #endif
        list
            .modifier(MessagePrefetchModifier(mailbox: mailbox))
            .overlay {
                if mailbox.listItems.isEmpty {
                    if mailbox.search.isActive {
                        emptySearch
                    } else if mailbox.isListPresentationReady {
                        // Until the selected mailbox's page arrives, an empty
                        // list says nothing about the mailbox or its download.
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
            .task(id: mailbox.accounts.map(\.account.id)) { await observeAddresses() }
            // Observations reports the latest request after any burst of changes.
            // .task(id:) skips a request that changes twice in one frame, which can
            // leave an empty mailbox waiting for a Gmail page nothing asks for.
            .task(id: ObjectIdentifier(mailbox)) {
                for await _ in Observations({ [mailbox] in mailbox.emptyMailboxLoadRequest }) {
                    mailbox.loadMoreForEmptyMailbox()
                }
            }
            .onChange(of: mailbox.listProjectionKey) { _, _ in
                // A search on its way shows no page yet, so the selection waits for one.
                if mailbox.isListPresentationReady {
                    mailbox.selectListRows(mailbox.selectedListRowIDs)
                }
                if mailbox.listItems.isEmpty, mailbox.search.isActive {
                    mailbox.search.loadMoreResults()
                }
            }
    }

    /// Double-click and Return open each chosen conversation in its own window, in list order.
    private func openConversations(_ ids: Set<MailListRowID>) {
        for row in mailbox.listItems where ids.contains(row.id) {
            openWindow(id: ConversationWindow.sceneID, value: mailbox.conversationLink(for: row.id))
        }
    }

    /// Mail is the section in front: neither the attachment library nor
    /// another section covers it.
    private var isInFront: Bool { Self.mailIsInFront(app, mailbox) }

    private static func mailIsInFront(_ app: AppModel, _ mailbox: MailboxModel) -> Bool {
        app.destination == .mail && !mailbox.showsAttachmentLibrary
    }

    /// Takes the keyboard from the list while another section covers Mail,
    /// so arrow keys can't change the hidden selection, and gives it back
    /// when Mail returns if the list had it. Only this view updates on a switch.
    private struct CoveredListFocus: View {
        @Environment(AppModel.self) private var app
        let mailbox: MailboxModel
        let isFocused: FocusState<Bool>.Binding
        @State private var refocusesOnReturn = false

        var body: some View {
            Color.clear
                .onChange(of: ThreadListView.mailIsInFront(app, mailbox)) { _, inFront in
                    if !inFront {
                        refocusesOnReturn = isFocused.wrappedValue
                        isFocused.wrappedValue = false
                    } else if refocusesOnReturn {
                        refocusesOnReturn = false
                        isFocused.wrappedValue = true
                    }
                }
        }
    }

    /// Space previews one conversation's first attachment. Other selections
    /// leave the key available to the native reading and scrolling path.
    private func previewAttachment() -> KeyPress.Result {
        let selection = mailbox.selectedListRowIDs
        guard selection.count == 1,
              let item = mailbox.listItems.first(where: { selection.contains($0.id) }),
              let attachment = item.attachments.first else { return .ignored }
        Task { previewURL = await mailbox.download(attachment) }
        return .handled
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
                if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, failedAccounts: mailbox.olderFailureAccounts,
                        action: mailbox.loadOlderConversations)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mailbox.selectedHaveSyncedOnce {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "No Conversations", systemImage: "tray", message: emptyDescription, fillsSpace: false)
                if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, failedAccounts: mailbox.olderFailureAccounts, action: mailbox.loadOlderConversations)
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
            // An account added or resumed in an open mailbox reads its saved sync
            // state as it starts, so its empty mailbox can pass through here.
            ProgressView {
                Text("Downloading mail…")
            }
            .ternDelayedLoading()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptySearch: some View {
        let search = mailbox.search
        if mailbox.searchResultsHiddenByFilters {
            VStack(spacing: Tokens.Space.s3) {
                TernEmptyState(title: "Results Hidden by Filters", systemImage: "line.3.horizontal.decrease.circle",
                    message: "Clear the filters to see the matching mail.", fillsSpace: false)
                Button("Clear Filters") { mailbox.listPreferences.filters = [] }
                if search.gmailState != .finished {
                    GmailRow(kind: .search, state: search.gmailState, action: search.askGmail)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
    }

    /// Keep the native scroll view mounted while mailbox and search states change.
    private var list: some View {
        MessageListSelectionSurface(mailbox: mailbox,
            rows: MessageListRows(mailbox: mailbox, rows: mailbox.listRowStates, dragNamespace: dragNamespace))
        .listStyle(.inset)
        .background { PerformanceScrollSurfaceMarker(name: "mailbox", isActive: true) }
        .overlayPreferenceValue(SnoozeDateAnchorKey.self) { SnoozeDatePopover(mailbox: mailbox, row: $0) }
        .listSenderPopover(mailbox: mailbox)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.top, Tokens.Space.s2, for: .scrollContent)
        // Dragging a selected row carries the whole selection.
        .dragContainer(for: ConversationDragItem.self, itemID: \.rowID, in: dragNamespace) { ids in
            mailbox.dragItems(for: ids)
        }
        .dragConfiguration(DragConfiguration(allowMove: true))
        .modifier(MessageListDragSelection(mailbox: mailbox, namespace: dragNamespace))
        .contextMenu(forSelectionType: MailListRowID.self) { ids in
            MessageListMenu(mailbox: mailbox, rows: ids)
        } primaryAction: { ids in
            openConversations(ids)
        }
        // Mail stays mounted behind the attachment library and the other
        // sections, so these keys act only while it is in front.
        .onDeleteCommand { if isInFront { mailbox.performDeleteKeyAction() } }
        .onKeyPress(.return) {
            guard isInFront, !mailbox.selectedListRowIDs.isEmpty else { return .ignored }
            openConversations(mailbox.selectedListRowIDs)
            return .handled
        }
        .onKeyPress(.space) { isInFront ? previewAttachment() : .ignored }
        .quickLookPreview($previewURL)
        .protectAttachmentPreview(previewURL)
        .focused($listFocused)
        .background { CoveredListFocus(mailbox: mailbox, isFocused: $listFocused) }
        .tracksKeyboardNavigation()
    }

    private var emptyDescription: String {
        if mailbox.selectedLabelID == SystemLabel.inbox { return mailbox.older?.state == .finished ? "Your inbox is empty." : "No inbox conversations are saved on this Mac." }
        if mailbox.showsSnoozed { return "Snoozed conversations wait here until they return to the Inbox." }
        if mailbox.older?.state == .finished { return "No conversations in this mailbox." }
        return "No conversations are saved on this Mac for this mailbox."
    }
}

/// Selection/content separation is informed by MishMail's MIT-licensed design:
/// https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Sources/MishMail/UI/ThreadListView.swift#L480-L541
/// Tern keeps its existing snapshot keys, account-qualified identities and row modifiers.
private struct MessageListSelectionSurface<Rows: View>: View {
    @Bindable var mailbox: MailboxModel
    let rows: Rows

    var body: some View {
        List(selection: $mailbox.selectedListRowIDs) { rows }
    }
}

/// A fresh selection binding must update AppKit, while unchanged row content
/// keeps its existing menus, swipe actions and identities. Conformance alone
/// preserves flattened tags; do not wrap this content in `.equatable()`.
/// A page with the same rows in the same order compares equal whatever
/// changed inside them: each `MessageListRowHost` observes its own row.
private struct MessageListRows: View, Equatable {
    let mailbox: MailboxModel
    let rows: [MessageListRowState]
    let dragNamespace: Namespace.ID
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mailbox === rhs.mailbox && lhs.dragNamespace == rhs.dragNamespace && lhs.rows.elementsEqual(rhs.rows, by: ===)
    }

    var body: some View {
        let isSearching = mailbox.search.isActive
        let accountMarks = compactAccountMarks
        let accountColors = AccountAppearance.colorIndexes(
            for: mailbox.accounts.map(\.account.id), stored: AccountAppearance.decode(storedColors)
        )
        let snoozeAnchor = snoozeDateAnchor(in: rows)
        // The next page starts loading while these rows scroll into view, so
        // it is ready before the user reaches the end.
        let paginationRows: Set<MailListRowID> = isSearching ? [] : Set(rows.suffix(MailboxModel.paginationLead).map(\.id))
        let lastRow = rows.last?.id
        // Keyed by account too, since thread IDs repeat across accounts.
        ForEach(rows) { row in
            #if TERN_TEST_SUPPORT || TERN_PERFORMANCE
            let _ = ThreadListView.onRowContentBuild?(mailbox, row.id)
            #endif
            MessageListRowHost(
                row: row, mailbox: mailbox,
                accountMark: accountMarks[row.id.accountID], accountColor: AccountAppearance.color(at: accountColors[row.id.accountID])
            )
                .tag(row.id)
                .draggable(containerItemID: row.id, containerNamespace: dragNamespace)
                // Only the first targeted row anchors the list's snooze popover.
                .background {
                    if snoozeAnchor == row.id {
                        Color.clear.anchorPreference(key: SnoozeDateAnchorKey.self, value: .bounds) { $0 }
                    }
                }
                .onAppear {
                    if isSearching {
                        if row.id == lastRow { mailbox.search.loadMoreResults() }
                    } else if paginationRows.contains(row.id) {
                        mailbox.loadMoreThreads()
                    }
                }
        }
        // Restart row appearance and pagination when entering or leaving search.
        .id(isSearching)
        // Apply outside the row wrappers so the native list receives these insets.
        // The column's resize gutter stays outside the list.
        .listRowInsets(.horizontal, -Tokens.Space.s2)
        if !rows.isEmpty { MessageListFooter(mailbox: mailbox) }
    }

    /// Choose Date & Time opens beside the first conversation it will snooze.
    private func snoozeDateAnchor(in rows: [MessageListRowState]) -> MailListRowID? {
        guard let keys = mailbox.snoozeDateTargets else { return nil }
        let targetRows = mailbox.snoozeRowTargets
        return rows.first { targetRows?.contains($0.id) ?? keys.contains($0.id.threadKey) }?.id
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
}

/// One row with the list traits that follow its content. It observes its own
/// row state, so a change to one conversation runs this body and no other.
/// Keep the body a single view: the list counts rows without building them.
private struct MessageListRowHost: View {
    let row: MessageListRowState
    let mailbox: MailboxModel
    let accountMark: String?
    let accountColor: Color

    var body: some View {
        let item = row.item
        #if TERN_TEST_SUPPORT || TERN_PERFORMANCE
        let _ = ThreadListView.onRowHostBuild?(mailbox, item.id)
        #endif
        MessageListRow(item: item, mailbox: mailbox, accountMark: accountMark, accountColor: accountColor)
            .listRowSeparator(row.hidesSeparator ? .hidden : .automatic, edges: .bottom)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                swipeButtons(first: mailbox.listPreferences.leadingFirst, second: mailbox.listPreferences.leadingSecond, item: item)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                swipeButtons(first: mailbox.listPreferences.trailingFirst, second: mailbox.listPreferences.trailingSecond, item: item)
            }
    }

    @ViewBuilder private func swipeButtons(first: MailSwipeAction, second: MailSwipeAction, item: MessageListItem) -> some View {
        swipeButton(first, item: item)
        swipeButton(second, item: item)
    }

    @ViewBuilder private func swipeButton(_ action: MailSwipeAction, item: MessageListItem) -> some View {
        if action != .none {
            let title = action.buttonTitle(isUnread: item.thread.isUnread, isStarred: item.thread.isStarred)
            Button { mailbox.performSwipe(action, on: item.id) } label: { Label(title, systemImage: action.symbol) }
                .tint(action == .trash || action == .spam ? .red : .accentColor)
                .disabled((action == .archive && !mailbox.offersArchive) || (action == .trash && !mailbox.offersTrash)
                          || (action == .snooze && !mailbox.offersArchive))
        }
    }
}

/// The row under the last conversation. It observes the mailbox on its own,
/// so a new page of the same rows doesn't build the rows above it again.
private struct MessageListFooter: View {
    let mailbox: MailboxModel

    var body: some View {
        if mailbox.search.isActive {
            let gmail = mailbox.search.gmailState
            if gmail != .finished {
                GmailRow(kind: .search, state: gmail, action: mailbox.search.askGmail)
            }
        } else if mailbox.offersOlderConversations {
            GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, failedAccounts: mailbox.olderFailureAccounts, action: mailbox.loadOlderConversations)
        }
    }
}

/// Keeps drag-selection observation separate from row construction.
private struct MessageListDragSelection: ViewModifier {
    let mailbox: MailboxModel
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        #if TERN_TEST_SUPPORT
        let _ = ThreadListView.onBodyBuild?(mailbox, .dragSelection)
        #endif
        content.dragContainerSelection(Array(mailbox.selectedListRowIDs), containerNamespace: namespace)
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
    var failedAccounts: String? = nil
    let action: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Space.s2) {
            if kind == .older, state != .finished {
                Text("More mail may be available in Gmail.").foregroundStyle(.secondary)
            }
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
                    Text(kind == .search ? "Searching Gmail…" : "Checking Gmail for more mail…")
                        .foregroundStyle(.secondary)
                }
            case .busy, .failed:
                Text(failedAccounts.map { "\(failure) Accounts: \($0)." } ?? failure)
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
        case (.older, _): "Load More from Gmail"
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
