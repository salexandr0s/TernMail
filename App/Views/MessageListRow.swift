import AppKit
import MailStore
import MessageContent
import SwiftUI

struct MessageListRow: View {
    let item: MessageListItem
    let mailbox: MailboxModel
    let isSelected: Bool
    let accountMark: String?
    let accountColor: Color
    @AppStorage(ReadingPreferences.textScaleKey) private var textScale = 1.0
    @State private var isHovered = false

    private var compact: Bool { mailbox.listPreferences.density == .compact }
    private let avatarSize = Tokens.Control.listAvatar
    private var scale: Double { ReadingPreferences.textScale(textScale) }
    private var thread: ThreadRecord { item.thread }
    private var displayedLabels: [LabelRecord] {
        let labels = mailbox.account(id: item.id.accountID)?.labels ?? []
        return item.displayedLabels(from: labels, mailboxID: mailbox.selectedLabelID)
    }
    /// Text starts past the unread dot and the avatar; the separator starts with it.
    private var textLeading: CGFloat { Tokens.Space.s1 + Tokens.Space.s1_5 * 3 + Tokens.Space.s0_5 + avatarSize }
    private var showsStar: Bool { thread.isStarred || isHovered || isSelected }

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.s1_5) {
            Circle().fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                .opacity(thread.isUnread ? 1 : 0)
            avatar
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                senderLine
                subjectLine
                if !compact { previewLine }
                if !displayedLabels.isEmpty || !item.attachments.isEmpty { detailLine }
            }
            .padding(.leading, Tokens.Space.s0_5)
        }
        .padding(.horizontal, Tokens.Space.s1)
        .padding(.vertical, Tokens.Space.s1)
        .onHover { isHovered = $0 }
        .alignmentGuide(.listRowSeparatorLeading) { _ in textLeading }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width - Tokens.Space.s1 }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var avatar: some View {
        if let sender = EmailAddress.parseList(item.messages.first?.message.sender ?? thread.participants).first {
            ContactAvatar(accountID: item.id.accountID, address: sender.address, name: sender.name ?? "",
                          cache: mailbox.cache, accounts: mailbox.accountStore, size: avatarSize)
        } else {
            TernAvatar(name: "", size: avatarSize)
        }
    }

    private var senderLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
            Text(senderText).font(.system(size: NSFont.preferredFont(forTextStyle: .body).pointSize * scale))
                .fontWeight(thread.isUnread ? .semibold : .regular).lineLimit(1)
            if thread.messageCount > 1 {
                Text("\(thread.messageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: Tokens.Space.s2)
            if mailbox.listPreferences.showsImportance, item.labels.contains(SystemLabel.important) {
                Image(systemName: "exclamationmark").font(.caption.weight(.semibold))
                    .foregroundStyle(Tokens.Status.important).accessibilityLabel("Important")
            }
            Button { mailbox.toggleListStar([item.id]) } label: {
                Image(systemName: thread.isStarred ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(thread.isStarred ? Tokens.Status.star : Color.secondary)
            }
            .buttonStyle(.borderless)
            // Unstarred rows show the star on hover, so the date column stays quiet.
            .opacity(showsStar ? 1 : 0)
            .help(thread.isStarred ? "Remove Star" : "Star")
            .accessibilityLabel(thread.isStarred ? "Remove Star" : "Star")
            Text(ThreadDate.short(thread.lastDate)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            if mailbox.listPreferences.showsAccountBadges, mailbox.listMixesAccounts, let accountMark {
                Text(accountMark).font(.caption2.weight(.medium)).padding(.horizontal, Tokens.Space.s1)
                    // Stays legible on the badge's own fill when the row's text turns white.
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .frame(minWidth: Tokens.Space.s5, minHeight: Tokens.Space.s4)
                    .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(accountColor, lineWidth: Tokens.Border.hairline) }
                    .fixedSize()
                    .help(mailbox.account(id: item.id.accountID).map { mailbox.accountTitle($0.account) } ?? item.id.accountID)
            }
        }
    }

    private var subjectLine: some View {
        HStack(spacing: Tokens.Space.s1) {
            if item.labels.contains(SystemLabel.draft) {
                Text("Draft").font(.caption.weight(.medium)).foregroundStyle(Tokens.Status.error)
            }
            Text(thread.subject.isEmpty ? "No Subject" : thread.subject)
                .font(.system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * scale))
                .fontWeight(thread.isUnread ? .medium : .regular)
                .foregroundStyle(thread.subject.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var previewLine: some View {
        if let wake = item.messages.first?.snoozeWakeAt ?? mailbox.wakeTimes[thread.key], mailbox.showsSnoozed {
            Label("Returns \(ThreadDate.wake(wake))", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        } else if !thread.snippet.isEmpty {
            Text(thread.snippet).font(.system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * scale))
                .foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var detailLine: some View {
        HStack(spacing: Tokens.Space.s1) {
            ForEach(Array(displayedLabels.prefix(2)), id: \.id) { label in
                Text(label.name).font(.caption2.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, Tokens.Space.s1_5).padding(.vertical, Tokens.Space.s0_5)
                    .foregroundStyle(Color(gmailHex: label.textColor) ?? .secondary)
                    .background(label.isSystem ? Color.clear : (Color(gmailHex: label.backgroundColor) ?? Tokens.Surface.muted), in: Capsule())
                    .overlay { Capsule().strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
            }
            if let attachment = item.attachments.first {
                Label(attachment.filename, systemImage: attachmentSymbol(attachment.mimeType)).font(.caption)
                    .lineLimit(1).help(attachment.filename)
                if item.attachments.count > 1 { Text("+\(item.attachments.count - 1)").font(.caption.monospacedDigit()).fixedSize() }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.top, Tokens.Space.s0_5)
    }

    private var senderText: String {
        if [SystemLabel.sent, SystemLabel.draft].contains(mailbox.selectedLabelID ?? ""), !item.recipients.isEmpty { return "To: " + item.recipients }
        return thread.participants.isEmpty ? "No Sender" : thread.participants
    }

    private func attachmentSymbol(_ type: String) -> String {
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        return "paperclip"
    }
}

struct MessageListMenu: View {
    let mailbox: MailboxModel
    let rows: Set<MailListRowID>
    var body: some View {
        Group {
            if mailbox.offersArchive { Button("Archive", systemImage: "archivebox") { mailbox.performListAction(.archive, rows: rows) } }
            if mailbox.offersTrash { Button("Move to Trash", systemImage: "trash") { mailbox.performListAction(.trash, rows: rows) } }
            Button("Read / Unread", systemImage: "envelope.open") { mailbox.toggleListRead(rows) }
            Button("Star / Unstar", systemImage: "star") { mailbox.toggleListStar(rows) }
            Divider()
            if rows.count == 1, let row = rows.first {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { mailbox.requestConversationWindow(for: row) }
                Button("Copy Link", systemImage: "link") {
                    if let url = MailLink(accountID: row.accountID, threadID: row.threadID).ternURL {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                Button("Open in Gmail", systemImage: "arrow.up.right.square") {
                    if let email = mailbox.account(id: row.accountID)?.account.email,
                       let url = MailLink(accountID: row.accountID, threadID: row.threadID).gmailURL(email: email) { NSWorkspace.shared.open(url) }
                }
                Button("Copy Gmail Link", systemImage: "link") {
                    if let email = mailbox.account(id: row.accountID)?.account.email,
                       let url = MailLink(accountID: row.accountID, threadID: row.threadID).gmailURL(email: email) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            }
            Button("Edit Labels…", systemImage: "tag") { mailbox.showEditLabels(forRows: rows) }
            Button("Move to…", systemImage: "folder") { mailbox.showMoveTo(forRows: rows) }
            if mailbox.snoozeKeeper != nil, mailbox.offersArchive {
                Menu("Snooze", systemImage: "clock") {
                    SnoozeMenuItems(onSnooze: { mailbox.snoozeRows(rows, until: $0) },
                                    onChooseDate: { mailbox.showSnoozeDate(forRows: rows) })
                }
            }
            if mailbox.showsSnoozed {
                Button("Unsnooze", systemImage: "clock.arrow.circlepath") { mailbox.unsnoozeRows(rows) }
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
