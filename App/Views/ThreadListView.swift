import MailStore
import SwiftUI

struct ThreadListView: View {
    @Bindable var mailbox: MailboxModel

    var body: some View {
        content
            .navigationTitle(mailbox.selectedLabelTitle)
            .toolbar { ThreadToolbar(mailbox: mailbox) }
    }

    @ViewBuilder
    private var content: some View {
        if !mailbox.threads.isEmpty {
            List(selection: $mailbox.selectedThreadIDs) {
                ForEach(mailbox.threads) { thread in
                    ThreadRow(thread: thread)
                        .onAppear {
                            if thread.id == mailbox.threads.last?.id { mailbox.loadMoreThreads() }
                        }
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                ThreadMenuItems(mailbox: mailbox, ids: ids)
            }
        } else if mailbox.hasSyncedOnce {
            ContentUnavailableView(
                "No Conversations",
                systemImage: "tray",
                description: Text(emptyDescription)
            )
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

    private var emptyDescription: String {
        if mailbox.selectedLabelID == SystemLabel.inbox { return "Your inbox is empty." }
        return "Tern keeps your inbox and the last 30 days of mail on this Mac."
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
        if mailbox.selectedLabelID != SystemLabel.trash, mailbox.selectedLabelID != SystemLabel.spam {
            Button("Archive") { mailbox.perform(.archive, on: ids) }
        }
        if mailbox.selectedLabelID != SystemLabel.trash {
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
