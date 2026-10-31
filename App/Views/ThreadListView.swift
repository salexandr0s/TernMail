import MailStore
import MessageContent
import SwiftUI

struct ThreadListView: View {
    @Bindable var mailbox: MailboxModel
    @AppStorage(AccountAppearance.storageKey) private var storedColors = Data()
    @FocusState private var listFocused: Bool

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
            .sheet(isPresented: isChoosingSnoozeDate) {
                if let ids = mailbox.snoozeDateTargets {
                    SnoozeDateSheet(
                        initial: SnoozeSchedule().wakeTime(for: .tomorrow, now: .now) ?? .now.addingTimeInterval(3600),
                        now: .now,
                        onSnooze: { mailbox.snooze(ids, until: $0) },
                        onCancel: { mailbox.snoozeDateTargets = nil }
                    )
                }
            }
    }

    private var isChoosingSnoozeDate: Binding<Bool> {
        Binding(get: { mailbox.snoozeDateTargets != nil }, set: { if !$0 { mailbox.snoozeDateTargets = nil } })
    }

    private var displayedThreads: [ThreadRecord] {
        mailbox.search.isActive ? mailbox.search.results : mailbox.threads
    }

    private var observationID: MessageListObservationID {
        .init(keys: displayedThreads.map(\.key), query: mailbox.search.text,
              remoteRevision: mailbox.search.gmail?.revision ?? 0, conversations: mailbox.listPreferences.conversations)
    }

    private func observeEntries(for keys: [ThreadKey]) async {
        guard !Task.isCancelled else { return }
        let visible = Set(keys)
        mailbox.listEntries = mailbox.listEntries.filter { visible.contains(ThreadKey(accountID: $0.message.accountID, threadID: $0.message.threadID)) }
        guard !keys.isEmpty else { mailbox.listEntries = []; return }
        let threadsByAccount = Dictionary(grouping: keys, by: \.accountID).mapValues { $0.map(\.threadID) }
        do {
            let query = mailbox.search.isActive && !mailbox.listPreferences.conversations ? SearchQuery(mailbox.search.text) : nil
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
                TernEmptyState(title: "No matching mail", systemImage: "line.3.horizontal.decrease.circle", message: "Try different filters or clear them to see all mail.", fillsSpace: false)
                Button("Clear Filters") { mailbox.listPreferences.filters = [] }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mailbox.selectedHaveSyncedOnce {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "No conversations", systemImage: "tray", message: emptyDescription, fillsSpace: false)
                if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, action: mailbox.loadOlderConversations)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if case .failed(let message) = mailbox.selectedSyncStatus {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(title: "Can't download mail", systemImage: "wifi.exclamationmark", message: message, fillsSpace: false)
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
        let gmail = search.gmail?.state ?? .ready
        if search.readFailed {
            TernEmptyState(
                title: "Can't search",
                systemImage: "exclamationmark.magnifyingglass",
                message: "Tern couldn't read the mail saved on this Mac."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if gmail == .loading {
            ProgressView {
                Text("Searching Gmail…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: Tokens.Space.s4) {
                TernEmptyState(
                    title: "No results",
                    systemImage: "magnifyingglass",
                    message: gmail == .finished
                        ? "No matches on this Mac or in Gmail."
                        : "No matches on this Mac.",
                    fillsSpace: false
                )
                if gmail != .finished {
                    GmailRow(kind: .search, state: gmail, action: search.askGmail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Keep the native scroll view mounted while mailbox and search states change.
    private var list: some View {
        let rows = mailbox.listItems
        let isSearching = mailbox.search.isActive
        let accountMarks = compactAccountMarks
        let accountColors = AccountAppearance.colorIndexes(
            for: mailbox.accounts.map(\.account.id), stored: AccountAppearance.decode(storedColors)
        )
        return List(selection: Binding(get: { mailbox.selectedListRowIDs }, set: { mailbox.selectListRows($0) })) {
            // Keyed by account too, since thread IDs repeat across accounts.
            ForEach(rows) { row in
                MessageListRow(
                    item: row, mailbox: mailbox, isSelected: mailbox.selectedListRowIDs.contains(row.id),
                    accountMark: accountMarks[row.id.accountID], accountColor: AccountAppearance.color(at: accountColors[row.id.accountID])
                )
                    .tag(row.id)
                    .listRowInsets(EdgeInsets())
                    .onTapGesture(count: 2) { mailbox.requestConversationWindow(for: row.id) }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        swipeButtons(first: mailbox.listPreferences.leadingFirst, second: mailbox.listPreferences.leadingSecond, row: row.id)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        swipeButtons(first: mailbox.listPreferences.trailingFirst, second: mailbox.listPreferences.trailingSecond, row: row.id)
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
            if !rows.isEmpty {
                if isSearching {
                    let gmail = mailbox.search.gmail?.state ?? .ready
                    if gmail != .finished {
                        GmailRow(kind: .search, state: gmail, action: mailbox.search.askGmail)
                    }
                } else if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, action: mailbox.loadOlderConversations)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contextMenu(forSelectionType: MailListRowID.self) { ids in
            MessageListMenu(mailbox: mailbox, rows: ids)
        }
        .focused($listFocused)
    }

    @ViewBuilder private func swipeButtons(first: MailSwipeAction, second: MailSwipeAction, row: MailListRowID) -> some View {
        swipeButton(first, row: row)
        swipeButton(second, row: row)
    }

    @ViewBuilder private func swipeButton(_ action: MailSwipeAction, row: MailListRowID) -> some View {
        if action != .none {
            Button { mailbox.performSwipe(action, on: row) } label: { Label(action.title, systemImage: action.symbol) }
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

struct ThreadRow: View {
    let thread: ThreadRecord
    /// Set in Snoozed, where the row shows when the conversation returns.
    var wakeAt: Date?
    /// A snooze brought the conversation back to the Inbox.
    var isWoken = false
    var isSelected = false
    var labels: [LabelRecord] = []
    /// Set where the list mixes accounts.
    var accountName: String?
    var accountMark: String?
    var accountColor: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s1_5) {
            Circle()
                .fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                .frame(width: Tokens.Space.s2)
                .padding(.top, Tokens.Space.s1)
                .opacity(thread.isUnread ? 1 : 0)

            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    Text(thread.participants.isEmpty ? "No Sender" : thread.participants)
                        .font(.body)
                        .fontWeight(thread.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                        .help(thread.participants)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Spacer(minLength: Tokens.Space.s1)
                    if thread.isStarred {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(.yellow)
                    }
                    if isWoken {
                        Image(systemName: "clock")
                            .imageScale(.small)
                            .foregroundStyle(.tint)
                    }
                    Text(ThreadDate.short(thread.lastDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    if let accountName, let accountMark {
                        Text(accountMark)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color(nsColor: .labelColor))
                            .padding(.horizontal, Tokens.Space.s1)
                            .frame(minWidth: Tokens.Space.s5, minHeight: Tokens.Space.s4)
                            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                            .overlay {
                                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                                    .strokeBorder(accountColor, lineWidth: Tokens.Border.hairline)
                            }
                            .fixedSize()
                            .help(accountName)
                    }
                }
                Text(thread.subject.isEmpty ? "No Subject" : thread.subject)
                    .font(.callout)
                    .fontWeight(thread.isUnread ? .medium : .regular)
                    .lineLimit(1)
                    .help(thread.subject)
                if let wakeAt {
                    Label("Returns \(ThreadDate.wake(wakeAt))", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Snoozed until \(ThreadDate.wake(wakeAt))")
                } else if !thread.snippet.isEmpty {
                    Text(thread.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !labels.isEmpty {
                    ThreadLabelChips(labels: labels)
                        .padding(.top, Tokens.Space.s0_5)
                }
            }
        }
        .padding(.vertical, Tokens.Space.s1_5)
        .alignmentGuide(.listRowSeparatorLeading) { _ in Tokens.Space.s2 + Tokens.Space.s1_5 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if thread.isUnread { parts.append("Unread") }
        if thread.isStarred { parts.append("Starred") }
        if isWoken { parts.append("Back from snooze") }
        parts.append(thread.participants)
        parts.append(thread.subject.isEmpty ? "No Subject" : thread.subject)
        if thread.messageCount > 1 { parts.append("\(thread.messageCount) messages") }
        if let wakeAt {
            parts.append("Snoozed until \(ThreadDate.wake(wakeAt))")
        } else {
            parts.append(ThreadDate.short(thread.lastDate))
        }
        if let accountName { parts.append("in \(accountName)") }
        if !labels.isEmpty { parts.append("Labels: \(labels.map(\.name).joined(separator: ", "))") }
        return parts.joined(separator: ", ")
    }
}

/// One line of labels, with the complete names available on hover and to VoiceOver.
private struct ThreadLabelChips: View {
    let labels: [LabelRecord]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array((1...min(labels.count, 3)).reversed()), id: \.self) { count in
                chips(count: count)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // A long first label can shrink, while the overflow count stays visible.
            chips(count: 1)
        }
        .help(labels.map(\.name).joined(separator: ", "))
    }

    private func chips(count: Int) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            ForEach(Array(labels.prefix(count)), id: \.id) { label in
                let icon = LabelAppearance.shared.icon(for: label)
                TernBadge(
                    text: label.name,
                    systemImage: icon == "tag" ? "tag.fill" : icon,
                    tint: Color(gmailHex: label.backgroundColor) ?? .secondary
                )
                .truncationMode(.middle)
            }
            if labels.count > count {
                Text("+\(labels.count - count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help(labels.dropFirst(count).map(\.name).joined(separator: ", "))
            }
        }
    }
}

/// Shared by the context menu so it acts on the clicked rows, not only the selection.
struct ThreadMenuItems: View {
    let mailbox: MailboxModel
    let ids: Set<ThreadKey>

    var body: some View {
        Group {
            if mailbox.offersArchive {
                Button("Archive", systemImage: "archivebox") { mailbox.perform(.archive, on: ids) }
            }
            if mailbox.offersTrash {
                Button("Move to Trash", systemImage: "trash") { mailbox.perform(.trash, on: ids) }
            }
            if mailbox.snoozeKeeper != nil, mailbox.offersArchive {
                Menu {
                    SnoozeMenuItems(
                        onSnooze: { mailbox.snooze(ids, until: $0) },
                        onChooseDate: { mailbox.showSnoozeDate(for: ids) }
                    )
                } label: {
                    Label("Snooze", systemImage: "clock")
                }
            }
            if mailbox.showsSnoozed {
                Button("Unsnooze", systemImage: "clock.arrow.circlepath") { mailbox.unsnooze(ids) }
            }
            Divider()
            Button(mailbox.allRead(ids) ? "Mark as Unread" : "Mark as Read", systemImage: mailbox.allRead(ids) ? "envelope.badge" : "envelope.open") { mailbox.toggleRead(ids) }
            Button(mailbox.allStarred(ids) ? "Remove Star" : "Star", systemImage: mailbox.allStarred(ids) ? "star.fill" : "star") { mailbox.toggleStar(ids) }
            Divider()
            Button("Edit Labels…", systemImage: "tag") { mailbox.showEditLabels(for: ids) }
            Button("Move to…", systemImage: "folder") { mailbox.showMoveTo(for: ids) }
        }
        .labelStyle(.titleAndIcon)
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
