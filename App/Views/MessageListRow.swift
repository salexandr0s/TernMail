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
    @AppStorage("mailTextScale") private var textScale = 1.0

    private var compact: Bool { mailbox.listPreferences.density == .compact }
    private let avatarSize = Tokens.Control.listAvatar
    private var scale: Double { min(1.5, max(0.85, textScale)) }
    private var thread: ThreadRecord { item.thread }
    private var displayedLabels: [LabelRecord] {
        let labels = mailbox.account(id: item.id.accountID)?.labels ?? []
        return item.displayedLabels(from: labels, mailboxID: mailbox.selectedLabelID)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s1) {
            Circle().fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                .padding(.top, Tokens.Space.s1)
                .opacity(thread.isUnread ? 1 : 0)
            if let sender = EmailAddress.parseList(item.messages.first?.message.sender ?? thread.participants).first {
                ContactAvatar(accountID: item.id.accountID, address: sender.address, name: sender.name ?? "",
                              cache: mailbox.cache, accounts: mailbox.accountStore,
                              size: avatarSize)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                    Text(senderText).font(.system(size: NSFont.preferredFont(forTextStyle: .body).pointSize * scale))
                        .fontWeight(thread.isUnread ? .semibold : .regular).lineLimit(1)
                    if thread.messageCount > 1 { Text("\(thread.messageCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize() }
                    Spacer(minLength: Tokens.Space.s1)
                    if mailbox.listPreferences.showsImportance, item.labels.contains(SystemLabel.important) {
                        Image(systemName: "exclamationmark").foregroundStyle(.orange).accessibilityLabel("Important")
                    }
                    Button { mailbox.toggleListStar([item.id]) } label: {
                        Image(systemName: thread.isStarred ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(thread.isStarred ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.borderless).help(thread.isStarred ? "Remove Star" : "Star")
                    .accessibilityLabel(thread.isStarred ? "Remove Star" : "Star")
                    Text(ThreadDate.short(thread.lastDate)).font(.caption).foregroundStyle(.secondary).fixedSize()
                    if mailbox.listPreferences.showsAccountBadges, mailbox.listMixesAccounts, let accountMark {
                        Text(accountMark).font(.caption2.weight(.medium)).padding(.horizontal, Tokens.Space.s1)
                            .frame(minWidth: Tokens.Space.s5, minHeight: Tokens.Space.s4)
                            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                            .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(accountColor, lineWidth: Tokens.Border.hairline) }
                            .fixedSize()
                            .help(mailbox.account(id: item.id.accountID).map { mailbox.accountTitle($0.account) } ?? item.id.accountID)
                    }
                }
                HStack(spacing: Tokens.Space.s1) {
                    if item.labels.contains(SystemLabel.draft) { Text("Draft").foregroundStyle(.red).font(.caption) }
                    Text(thread.subject.isEmpty ? "No Subject" : thread.subject)
                        .font(.system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * scale))
                        .fontWeight(thread.isUnread ? .medium : .regular).lineLimit(1)
                }
                if !compact {
                    if let wake = item.messages.first?.snoozeWakeAt ?? mailbox.wakeTimes[thread.key], mailbox.showsSnoozed {
                        Label("Returns \(ThreadDate.wake(wake))", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    } else if !thread.snippet.isEmpty {
                        Text(thread.snippet).font(.system(size: NSFont.preferredFont(forTextStyle: .callout).pointSize * scale))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !displayedLabels.isEmpty || !item.attachments.isEmpty {
                    HStack(spacing: Tokens.Space.s1) {
                        ForEach(Array(displayedLabels.prefix(2)), id: \.id) { label in
                            Text(label.name).font(.caption2).lineLimit(1).padding(.horizontal, Tokens.Space.s1)
                                .foregroundStyle(Color(gmailHex: label.textColor) ?? .secondary)
                                .background(label.isSystem ? Color.clear : (Color(gmailHex: label.backgroundColor) ?? Tokens.Surface.muted),
                                            in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                                .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
                        }
                        if let attachment = item.attachments.first {
                            Label(attachment.filename, systemImage: attachmentSymbol(attachment.mimeType)).font(.caption2)
                                .lineLimit(1).help(attachment.filename)
                            if item.attachments.count > 1 { Text("+\(item.attachments.count - 1)").font(.caption2).fixedSize() }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Tokens.Space.s0_5)
        .alignmentGuide(.listRowSeparatorLeading) { _ in Tokens.Space.s1_5 + avatarSize + Tokens.Space.s1 * 2 }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
        .accessibilityElement(children: .contain)
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
