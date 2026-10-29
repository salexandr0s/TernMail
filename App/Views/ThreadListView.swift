import MailStore
import SwiftUI

struct ThreadListView: View {
    @Bindable var mailbox: MailboxModel
    @FocusState private var listFocused: Bool

    var body: some View {
        content
            .navigationTitle(mailbox.selectedLabelTitle)
            .toolbar { ThreadToolbar(mailbox: mailbox) }
            .onChange(of: mailbox.search.listFocusRequest) { listFocused = true }
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
        } else if mailbox.hasSyncedOnce {
            ContentUnavailableView {
                Label("No Conversations", systemImage: "tray")
            } description: {
                Text(emptyDescription)
            } actions: {
                if mailbox.offersOlderConversations {
                    GmailRow(kind: .older, state: mailbox.older?.state ?? .ready, action: mailbox.loadOlderConversations)
                }
            }
        } else if case .failed(let message) = mailbox.syncStatus {
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
        if search.readFailed {
            ContentUnavailableView(
                "Can't Search",
                systemImage: "exclamationmark.magnifyingglass",
                description: Text("Tern couldn't read its mail cache.")
            )
        } else if !search.results.isEmpty {
            list(search.results, onEnd: search.loadMoreResults) {
                if gmail != .finished {
                    GmailRow(kind: .search, state: gmail, action: search.askGmail)
                }
            }
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
        List(selection: $mailbox.selectedThreadIDs) {
            ForEach(threads) { thread in
                ThreadRow(thread: thread)
                    .onAppear {
                        if thread.id == threads.last?.id { onEnd() }
                    }
            }
            footer()
        }
        .contextMenu(forSelectionType: String.self) { ids in
            ThreadMenuItems(mailbox: mailbox, ids: ids)
        }
        .focused($listFocused)
    }

    private var emptyDescription: String {
        if mailbox.selectedLabelID == SystemLabel.inbox { return "Your inbox is empty." }
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
                    Text(ThreadDate.short(thread.lastDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(thread.subject.isEmpty ? "No Subject" : thread.subject)
                    .fontWeight(thread.isUnread ? .medium : .regular)
                    .lineLimit(1)
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
        parts.append(thread.participants)
        parts.append(thread.subject.isEmpty ? "No Subject" : thread.subject)
        parts.append(ThreadDate.short(thread.lastDate))
        return parts.joined(separator: ", ")
    }
}

/// Shared by the context menu so it acts on the clicked rows, not only the selection.
struct ThreadMenuItems: View {
    let mailbox: MailboxModel
    let ids: Set<String>

    var body: some View {
        if mailbox.offersArchive {
            Button("Archive") { mailbox.perform(.archive, on: ids) }
        }
        if mailbox.offersTrash {
            Button("Move to Trash") { mailbox.perform(.trash, on: ids) }
        }
        Divider()
        Button(mailbox.allRead(ids) ? "Mark as Unread" : "Mark as Read") { mailbox.toggleRead(ids) }
        Button(mailbox.allStarred(ids) ? "Remove Star" : "Star") { mailbox.toggleStar(ids) }
    }
}

private struct ThreadToolbar: ToolbarContent {
    let mailbox: MailboxModel

    var body: some ToolbarContent {
        let ids = mailbox.selectedThreadIDs
        let isRead = mailbox.allRead(ids)
        let isStarred = mailbox.allStarred(ids)
        ToolbarItemGroup(placement: .primaryAction) {
            Button { mailbox.perform(.archive) } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Archive")
            .disabled(!mailbox.canArchive)

            Button { mailbox.perform(.trash) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move to Trash")
            .disabled(!mailbox.canTrash)

            Button { mailbox.toggleRead() } label: {
                Label(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open")
            }
            .help(isRead ? "Mark as Unread" : "Mark as Read")
            .disabled(ids.isEmpty)

            Button { mailbox.toggleStar() } label: {
                Label(isStarred ? "Remove Star" : "Star", systemImage: isStarred ? "star.slash" : "star")
            }
            .help(isStarred ? "Remove Star" : "Star")
            .disabled(ids.isEmpty)
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
}
