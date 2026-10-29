import MailStore
import SwiftUI

struct ThreadListView: View {
    @Bindable var mailbox: MailboxModel
    @FocusState private var listFocused: Bool

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if mailbox.showsSnoozed {
                    Text("Snoozes stay on this Mac and don't show in Gmail or on other devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Space.s3)
                        .padding(.vertical, Tokens.Space.s2)
                        .background(.bar)
                }
            }
            .navigationTitle(mailbox.selectedLabelTitle)
            .navigationSubtitle(mailbox.selectedMailboxSubtitle)
            .onChange(of: mailbox.search.listFocusRequest) { listFocused = true }
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

    @ViewBuilder
    private var content: some View {
        if mailbox.search.isActive {
            searchResults
        } else if !mailbox.threads.isEmpty {
            list(mailbox.threads, onEnd: mailbox.loadMoreThreads) {
                if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, action: mailbox.loadOlderConversations)
                }
            }
        } else if mailbox.selectedHaveSyncedOnce {
            ContentUnavailableView {
                Label("No Conversations", systemImage: "tray")
            } description: {
                Text(emptyDescription)
            } actions: {
                if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, action: mailbox.loadOlderConversations)
                }
            }
        } else if case .failed(let message) = mailbox.selectedSyncStatus {
            ContentUnavailableView {
                Label("Can't Download Your Mail", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { mailbox.syncNow() }
            }
        } else {
            ProgressView {
                Text("Downloading your mail…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Local matches as the user types, then Gmail's, with Gmail's state last.
    @ViewBuilder
    private var searchResults: some View {
        let search = mailbox.search
        let gmail = search.gmail?.state ?? .ready
        if !search.results.isEmpty {
            list(search.results, onEnd: search.loadMoreResults) {
                if gmail != .finished {
                    GmailRow(kind: .search, state: gmail, action: search.askGmail)
                }
            }
        } else if search.readFailed {
            ContentUnavailableView(
                "Can't Search",
                systemImage: "exclamationmark.magnifyingglass",
                description: Text("Tern couldn't read its mail cache.")
            )
        } else if gmail == .loading {
            ProgressView {
                Text("Searching Gmail…")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                if gmail == .finished {
                    Text("Nothing on this Mac or in Gmail matches your search.")
                } else {
                    Text("Nothing on this Mac matches your search.")
                }
            } actions: {
                if gmail != .finished {
                    GmailRow(kind: .search, state: gmail, action: search.askGmail)
                }
            }
        }
    }

    private func list(
        _ threads: [ThreadRecord], onEnd: @escaping () -> Void, @ViewBuilder footer: () -> some View
    ) -> some View {
        let wakeTimes = mailbox.showsSnoozed ? mailbox.wakeTimes : [:]
        let namesAccounts = mailbox.listMixesAccounts
        return List(selection: $mailbox.selectedThreadIDs) {
            // Keyed by account too, since thread IDs repeat across accounts.
            ForEach(threads, id: \.key) { thread in
                ThreadRow(
                    thread: thread,
                    wakeAt: wakeTimes[thread.key],
                    isWoken: mailbox.isWoken(thread),
                    accountName: namesAccounts ? mailbox.account(id: thread.accountID)?.account.email : nil
                )
                    .onAppear {
                        if thread.key == threads.last?.key { onEnd() }
                    }
            }
            footer()
        }
        .contextMenu(forSelectionType: ThreadKey.self) { ids in
            ThreadMenuItems(mailbox: mailbox, ids: ids)
        }
        .focused($listFocused)
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
        VStack(spacing: Tokens.Space.s1) {
            switch state {
            case .ready, .more:
                Button(buttonTitle, action: action)
                    .buttonStyle(.link)
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
                    .buttonStyle(.link)
            case .finished:
                EmptyView()
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Space.s2)
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
        case (.search, .busy): "Gmail is busy, so these results come from this Mac only."
        case (.search, _): "Tern couldn't reach Gmail, so these results come from this Mac only."
        case (.older, .busy): "Gmail is busy. Try again in a moment."
        case (.older, _): "Tern couldn't reach Gmail. Check your connection."
        }
    }
}

struct ThreadRow: View {
    let thread: ThreadRecord
    /// Set in Snoozed, where the row shows when the conversation returns.
    var wakeAt: Date?
    /// A snooze brought the conversation back to the Inbox.
    var isWoken = false
    /// Set where the list mixes accounts.
    var accountName: String?

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Circle()
                .fill(.tint)
                .frame(width: Tokens.Space.s2, height: Tokens.Space.s2)
                .padding(.top, Tokens.Space.s1_5)
                .opacity(thread.isUnread ? 1 : 0)

            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    Text(thread.participants.isEmpty ? "No Sender" : thread.participants)
                        .fontWeight(thread.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Tokens.Space.s2)
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
                    if let wakeAt {
                        Label(ThreadDate.wake(wakeAt), systemImage: "clock")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(ThreadDate.short(thread.lastDate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    Text(thread.subject.isEmpty ? "No Subject" : thread.subject)
                        .fontWeight(thread.isUnread ? .medium : .regular)
                        .lineLimit(1)
                    if let accountName {
                        Spacer(minLength: Tokens.Space.s2)
                        Text(accountName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(-1)
                    }
                }
                Text(thread.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Tokens.Space.s1)
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
        if let wakeAt {
            parts.append("Snoozed until \(ThreadDate.wake(wakeAt))")
        } else {
            parts.append(ThreadDate.short(thread.lastDate))
        }
        if let accountName { parts.append("in \(accountName)") }
        return parts.joined(separator: ", ")
    }
}

/// Shared by the context menu so it acts on the clicked rows, not only the selection.
struct ThreadMenuItems: View {
    let mailbox: MailboxModel
    let ids: Set<ThreadKey>

    var body: some View {
        if mailbox.offersArchive {
            Button("Archive") { mailbox.perform(.archive, on: ids) }
        }
        if mailbox.offersTrash {
            Button("Move to Trash") { mailbox.perform(.trash, on: ids) }
        }
        if mailbox.snoozeKeeper != nil, mailbox.offersArchive {
            Menu("Snooze") {
                SnoozeMenuItems(
                    onSnooze: { mailbox.snooze(ids, until: $0) },
                    onChooseDate: { mailbox.showSnoozeDate(for: ids) }
                )
            }
        }
        if mailbox.showsSnoozed {
            Button("Unsnooze") { mailbox.unsnooze(ids) }
        }
        Divider()
        Button(mailbox.allRead(ids) ? "Mark as Unread" : "Mark as Read") { mailbox.toggleRead(ids) }
        Button(mailbox.allStarred(ids) ? "Remove Star" : "Star") { mailbox.toggleStar(ids) }
        Divider()
        Button("Edit Labels…") { mailbox.showEditLabels(for: ids) }
        Button("Move to…") { mailbox.showMoveTo(for: ids) }
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
