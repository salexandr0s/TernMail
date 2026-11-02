import AppKit
import MailStore
import MessageContent
import SwiftUI

struct MessageListRow: View {
    let item: MessageListItem
    let mailbox: MailboxModel
    let accountMark: String?
    let accountColor: Color

    #if DEBUG || TERN_PERFORMANCE
    struct RenderState: Equatable {
        let selected: Bool
        let unread: Bool
        let starred: Bool
        let textScale: Double
        let compact: Bool
    }
    static var onBodyEvaluation: ((MailboxModel, MailListRowID, RenderState) -> Void)?
    static var onSelectionObserverEvaluation: ((MailboxModel, MailListRowID) -> Void)?
    #endif

    /// Observe selection at the realized row, outside the ForEach content closure.
    private var isSelected: Bool {
        mailbox.listPreferences.conversations
            ? mailbox.selectedThreadIDs.contains(item.id.threadKey)
            : mailbox.selectedMessageRows.contains(item.id)
    }

    var body: some View {
        #if DEBUG || TERN_PERFORMANCE
        let _ = Self.onSelectionObserverEvaluation?(mailbox, item.id)
        #endif
        MessageListVisualRow(item: item, mailbox: mailbox, selected: isSelected,
            dateKey: ThreadDate.short(item.thread.lastDate), accountMark: accountMark, accountColor: accountColor)
            .background {
                if NavigationPerformance.rowFeedbackDiagnosticsEnabled {
                    RowSelectionFeedbackDiagnostic(mailbox: mailbox, row: item.id)
                }
            }
    }

    /// VoiceOver reads the row as one line: state first, then who, what and when.
    static func accessibilitySummary(unread: Bool, sender: String, subject: String, date: String,
                                     messageCount: Int, starred: Bool, important: Bool = false,
                                     labels: [String] = [], attachments: Int = 0, account: String? = nil) -> String {
        var parts: [String] = []
        if unread { parts.append("Unread") }
        parts.append(sender)
        parts.append(subject.isEmpty ? "No Subject" : subject)
        parts.append(date)
        if messageCount > 1 { parts.append("\(messageCount) messages") }
        if starred { parts.append("starred") }
        if important { parts.append("important") }
        if attachments == 1 { parts.append("1 attachment") } else if attachments > 1 { parts.append("\(attachments) attachments") }
        if !labels.isEmpty { parts.append("labels " + labels.joined(separator: ", ")) }
        if let account { parts.append("in \(account)") }
        return parts.joined(separator: ", ")
    }
}

/// Stable per-realized-row native probes exist only for explicit diagnostics.
/// Keep their observation dependencies outside the actual visual row content.
private struct RowSelectionFeedbackDiagnostic: View {
    @Environment(AppModel.self) private var app
    let mailbox: MailboxModel
    let row: MailListRowID

    private static func isCurrent(app: AppModel, mailbox: MailboxModel, accountOwner: AccountMailbox,
                                  row: MailListRowID) -> Bool {
        guard app.destination == .mail, app.mailbox === mailbox,
              mailbox.account(id: row.accountID) === accountOwner else { return false }
        if mailbox.listPreferences.conversations {
            return mailbox.selectedThreadIDs.count == 1 && mailbox.selectedThreadIDs.contains(row.threadKey)
        }
        return mailbox.selectedMessageRows.count == 1 && mailbox.selectedMessageRows.contains(row)
    }

    var body: some View {
        if let accountOwner = mailbox.account(id: row.accountID) {
            VisibleContentProbe(selectedRow: .init(identity: .init(owner: ObjectIdentifier(mailbox),
                accountOwner: ObjectIdentifier(accountOwner), row: row),
                isCurrent: { [weak app, weak mailbox, weak accountOwner, row] in
                    guard let app, let mailbox, let accountOwner else { return false }
                    return Self.isCurrent(app: app, mailbox: mailbox, accountOwner: accountOwner, row: row)
                }), isActive: Self.isCurrent(app: app, mailbox: mailbox, accountOwner: accountOwner, row: row))
        }
    }
}

/// Selection changes reach each observer, while unchanged visual content keeps
/// its existing view graph. Settings and row interaction state remain live here.
private struct MessageListVisualRow: View, Equatable {
    let item: MessageListItem
    let mailbox: MailboxModel
    let selected: Bool
    let dateKey: String
    let accountMark: String?
    let accountColor: Color
    @AppStorage(ReadingPreferences.textScaleKey) private var textScale = 1.0
    @Environment(\.backgroundProminence) private var prominence
    @State private var isHovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mailbox === rhs.mailbox && lhs.selected == rhs.selected && lhs.dateKey == rhs.dateKey
            && lhs.accountMark == rhs.accountMark && lhs.accountColor == rhs.accountColor && lhs.item == rhs.item
    }

    private var compact: Bool { mailbox.listPreferences.density == .compact }
    private let avatarSize = Tokens.Control.listAvatar
    private var scale: Double { ReadingPreferences.textScale(textScale) }
    private var thread: ThreadRecord { item.thread }
    private var displayedLabels: [LabelRecord] { item.visibleLabels }
    /// Text starts past the unread dot and the avatar; the separator starts with it.
    private var textLeading: CGFloat { Tokens.Space.s1 + Tokens.Space.s1_5 * 3 + Tokens.Space.s0_5 + avatarSize }
    private var showsStar: Bool { thread.isStarred || isHovered || selected }
    private var senderLineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: MessageListFontMetrics.size(for: .body) * scale)
        return max(avatarSize, ceil(font.ascender - font.descender + font.leading))
    }
    /// Set in Snoozed, where the row shows when the conversation returns.
    private var wakeTime: Date? {
        guard mailbox.showsSnoozed else { return nil }
        return item.messages.first?.snoozeWakeAt ?? mailbox.wakeTimes[thread.key]
    }

    /// Row text follows the reader's text size, so dates and counts keep pace with the subject.
    private func scaledFont(_ style: NSFont.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(size: MessageListFontMetrics.size(for: style) * scale, weight: weight)
    }

    private var labelFont: Font { .system(size: NSFont.systemFontSize(for: .mini) * scale) }

    var body: some View {
        // alignmentGuide closures are Sendable, so they take a copy rather than reading the view.
        let separatorLeading = textLeading
        let labels = displayedLabels
        let lineHeight = senderLineHeight
        let date = dateKey
        #if DEBUG || TERN_PERFORMANCE
        let _ = MessageListRow.onBodyEvaluation?(mailbox, item.id,
            MessageListRow.RenderState(selected: selected, unread: thread.isUnread, starred: thread.isStarred,
                                       textScale: scale, compact: compact))
        #endif
        HStack(alignment: .top, spacing: Tokens.Space.s1_5) {
            Circle().fill(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                .frame(height: lineHeight)
                .opacity(thread.isUnread ? 1 : 0)
            avatar
                .frame(height: lineHeight)
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                senderLine(date: date)
                    .frame(minHeight: lineHeight)
                subjectLine
                if !compact { previewLine }
                if !labels.isEmpty || !item.attachments.isEmpty { detailLine(labels: labels) }
            }
            .padding(.leading, Tokens.Space.s0_5)
        }
        .padding(.horizontal, Tokens.Space.s1)
        .padding(.vertical, compact ? Tokens.Space.s1 : Tokens.Space.s1_5)
        .onHover { isHovered = $0 }
        .ternHover(isEnabled: !selected)
        .alignmentGuide(.listRowSeparatorLeading) { _ in separatorLeading }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width - Tokens.Space.s1 }
        // One element per row: VoiceOver reads the state, then who, what and when.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(labels: labels, date: date))
    }

    @ViewBuilder private var avatar: some View {
        if let sender = item.sender {
            ContactAvatar(accountID: item.id.accountID, address: sender.address, name: sender.name ?? "",
                          cache: mailbox.cache, accounts: mailbox.accountStore, size: avatarSize)
        } else {
            TernAvatar(name: "", size: avatarSize)
        }
    }

    private func senderLine(date: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
            Text(senderText).font(scaledFont(.body, weight: thread.isUnread ? .semibold : .medium)).lineLimit(1)
            if thread.messageCount > 1 {
                Text("\(thread.messageCount)").font(scaledFont(.caption1).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: Tokens.Space.s2)
            if mailbox.listPreferences.showsImportance, item.labels.contains(SystemLabel.important) {
                Image(systemName: "exclamationmark").font(scaledFont(.caption1, weight: .semibold))
                    .foregroundStyle(Tokens.Status.important).accessibilityLabel("Important")
            }
            Button { mailbox.toggleListStar([item.id]) } label: {
                Image(systemName: thread.isStarred ? "star.fill" : "star")
                    .font(scaledFont(.caption1))
                    .foregroundStyle(thread.isStarred ? Tokens.Status.star : Color.secondary)
            }
            .buttonStyle(.borderless)
            // Unstarred rows show the star on hover, so the date column stays quiet.
            .opacity(showsStar ? 1 : 0)
            .help(thread.isStarred ? "Remove Star" : "Star")
            .accessibilityLabel(thread.isStarred ? "Remove Star" : "Star")
            Text(date).font(scaledFont(.caption1).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
            if mailbox.listPreferences.showsAccountBadges, mailbox.listMixesAccounts, let accountMark {
                HStack(spacing: Tokens.Space.s0_5) {
                    // The account's color would vanish on an accent-colored selection.
                    Circle().fill(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(accountColor))
                        .frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                    Text(accountMark).font(scaledFont(.caption2, weight: .medium)).foregroundStyle(.secondary)
                }
                .fixedSize()
                .help(mailbox.account(id: item.id.accountID).map { mailbox.accountTitle($0.account) } ?? item.id.accountID)
            }
        }
    }

    private var subjectLine: some View {
        HStack(spacing: Tokens.Space.s1) {
            if item.labels.contains(SystemLabel.draft) {
                Text("Draft").font(scaledFont(.caption1, weight: .medium)).foregroundStyle(Tokens.Status.error)
            }
            Text(thread.subject.isEmpty ? AttributedString("No Subject") : mailbox.search.highlights.subject(thread.subject))
                .font(scaledFont(.callout, weight: thread.isUnread ? .medium : .regular))
                .foregroundStyle(thread.subject.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var previewLine: some View {
        if let wake = wakeTime {
            Label("Returns \(ThreadDate.wake(wake))", systemImage: "clock").font(scaledFont(.caption1)).foregroundStyle(.secondary)
        } else if !thread.snippet.isEmpty {
            Text(mailbox.search.highlights.preview(thread.snippet)).font(scaledFont(.caption1)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func detailLine(labels: [LabelRecord]) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            ForEach(Array(labels.prefix(2)), id: \.id) { label in
                MailLabelBadge(label: label, font: labelFont)
            }
            if labels.count > 2 {
                Text("+\(labels.count - 2)")
                    .font(labelFont.monospacedDigit())
                    .fixedSize()
                    .help(labels.dropFirst(2).map(\.title).joined(separator: ", "))
            }
            if let attachment = item.attachments.first {
                if labels.isEmpty {
                    Label(attachment.filename, systemImage: attachmentSymbol(attachment.mimeType))
                        .font(scaledFont(.caption1))
                        .lineLimit(1).help(attachment.filename)
                    if item.attachments.count > 1 {
                        Text("+\(item.attachments.count - 1)")
                            .font(scaledFont(.caption1).monospacedDigit()).fixedSize()
                    }
                } else {
                    Label("\(item.attachments.count)", systemImage: "paperclip")
                        .font(labelFont.monospacedDigit())
                        .fixedSize()
                        .help(item.attachments.map(\.filename).joined(separator: "\n"))
                        .accessibilityLabel(item.attachments.map(\.filename).joined(separator: ", "))
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.top, Tokens.Space.s0_5)
    }

    private var senderText: String {
        if [SystemLabel.sent, SystemLabel.draft].contains(mailbox.selectedLabelID ?? ""), !item.recipients.isEmpty { return "To: " + item.recipients }
        return thread.participants.isEmpty ? "No Sender" : thread.participants
    }

    private func accessibilitySummary(labels: [LabelRecord], date: String) -> String {
        let account = mailbox.listMixesAccounts
            ? mailbox.account(id: item.id.accountID).map { mailbox.accountTitle($0.account) } : nil
        return MessageListRow.accessibilitySummary(
            unread: thread.isUnread, sender: senderText, subject: thread.subject,
            date: wakeTime.map { "Returns \(ThreadDate.wake($0))" } ?? date,
            messageCount: thread.messageCount, starred: thread.isStarred,
            important: mailbox.listPreferences.showsImportance && item.labels.contains(SystemLabel.important),
            labels: labels.map(\.title), attachments: item.attachments.count, account: account)
    }

    private func attachmentSymbol(_ type: String) -> String {
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        return "paperclip"
    }
}

/// Opaque fills keep a label's color and text contrast when its row is selected.
private struct MailLabelBadge: View {
    let label: LabelRecord
    let font: Font
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let colors = LabelAppearance.shared.badgeColor(for: label)
        let icon = LabelAppearance.shared.icon(for: label)
        HStack(spacing: Tokens.Space.s0_5) {
            if icon != "tag" {
                Image(systemName: icon).accessibilityHidden(true)
            }
            Text(label.title).lineLimit(1)
        }
        .font(font)
        .foregroundStyle(Color(gmailHex: colors.textColor) ?? .primary)
        .padding(.horizontal, Tokens.Space.s1)
        .background(Color(gmailHex: colors.backgroundColor) ?? Tokens.Surface.muted,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : Tokens.Opacity.tint),
                              lineWidth: Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
        .help(label.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.title)
    }
}

/// Native font lookup can invoke AppKit layout/font machinery. Every row uses
/// the same metrics; the reader's text scale remains a live per-view setting.
@MainActor
private enum MessageListFontMetrics {
    private static var sizes: [NSFont.TextStyle: CGFloat] = [:]

    static func size(for style: NSFont.TextStyle) -> CGFloat {
        if let value = sizes[style] { return value }
        let value = NSFont.preferredFont(forTextStyle: style).pointSize
        sizes[style] = value
        return value
    }
}

struct MessageListMenu: View {
    let mailbox: MailboxModel
    let rows: Set<MailListRowID>
    var body: some View {
        Group {
            if mailbox.offersArchive { Button("Archive", systemImage: "archivebox") { mailbox.performListAction(.archive, rows: rows) } }
            if mailbox.offersTrash { Button("Move to Trash", systemImage: "trash") { mailbox.performListAction(.trash, rows: rows) } }
            let allRead = mailbox.allListRead(rows)
            Button(allRead ? "Mark as Unread" : "Mark as Read", systemImage: allRead ? "envelope.badge" : "envelope.open") {
                mailbox.toggleListRead(rows)
            }
            let allStarred = mailbox.allListStarred(rows)
            Button(allStarred ? "Remove Star" : "Star", systemImage: allStarred ? "star.fill" : "star") { mailbox.toggleListStar(rows) }
            Divider()
            if rows.count == 1, let row = rows.first {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { mailbox.requestConversationWindow(for: row) }
                Button("Copy Link", systemImage: "link") {
                    if let url = MailLink(accountID: row.accountID, threadID: row.threadID).ternURL {
                        NSPasteboard.general.replaceContents(with: url.absoluteString)
                    }
                }
                Button("Open in Gmail", systemImage: "arrow.up.right.square") {
                    if let email = mailbox.account(id: row.accountID)?.account.email,
                       let url = MailLink(accountID: row.accountID, threadID: row.threadID).gmailURL(email: email) { NSWorkspace.shared.open(url) }
                }
                Button("Copy Gmail Link", systemImage: "link") {
                    if let email = mailbox.account(id: row.accountID)?.account.email,
                       let url = MailLink(accountID: row.accountID, threadID: row.threadID).gmailURL(email: email) {
                        NSPasteboard.general.replaceContents(with: url.absoluteString)
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
