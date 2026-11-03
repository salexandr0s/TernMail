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
            .listRowSeparatorTint(Tokens.MessageList.separator)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var showsSender = false
    @FocusState private var starFocused: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mailbox === rhs.mailbox && lhs.selected == rhs.selected && lhs.dateKey == rhs.dateKey
            && lhs.accountMark == rhs.accountMark && lhs.accountColor == rhs.accountColor && lhs.item == rhs.item
    }

    private var compact: Bool { mailbox.listPreferences.density == .compact }
    private let avatarSize = Tokens.Control.listAvatar
    private var scale: Double { ReadingPreferences.textScale(textScale) }
    private var thread: ThreadRecord { item.thread }
    private var textWeight: Font.Weight {
        thread.isUnread ? Tokens.MessageList.unreadWeight : Tokens.MessageList.readWeight
    }
    private var displayedLabels: [LabelRecord] { item.visibleLabels }
    /// Only the unread gutter spans the row; the avatar belongs to the header.
    private var textLeading: CGFloat { Tokens.Space.s1 + Tokens.Space.s2 + Tokens.Space.s1_5 }
    private var showsStar: Bool { thread.isStarred || isHovered || selected || starFocused }
    private var showsAccount: Bool {
        mailbox.listPreferences.showsAccountBadges && mailbox.listMixesAccounts && accountMark != nil
    }
    private var accountDescription: String {
        guard let account = mailbox.account(id: item.id.accountID)?.account else { return item.id.accountID }
        let title = mailbox.accountTitle(account)
        return title == account.email ? title : "\(title) (\(account.email))"
    }
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
                .frame(width: Tokens.Space.s2, height: Tokens.Space.s2)
                .frame(height: lineHeight)
                .opacity(thread.isUnread ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                senderLine(date: date)
                    .frame(minHeight: lineHeight)
                subjectLine
                if !compact { previewLine }
                if !labels.isEmpty || !item.attachments.isEmpty || showsAccount { detailLine(labels: labels) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Tokens.Space.s1)
        .padding(.vertical, Tokens.Space.s1)
        .ternHover(isEnabled: !selected)
        .background {
            if !selected {
                let shape = RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                shape
                    .fill(Tokens.MessageList.backgroundTint(isUnread: thread.isUnread, colorScheme: colorScheme))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onHover { isHovered = $0 }
        .alignmentGuide(.listRowSeparatorLeading) { _ in separatorLeading }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width - Tokens.Space.s1 }
        // One element per row: VoiceOver reads the state, then who, what and when.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(labels: labels, date: date))
        .accessibilityAction(named: "Show sender details") {
            if item.sender != nil { showsSender = true }
        }
        .onChange(of: item.id) { _, _ in showsSender = false }
    }

    @ViewBuilder private var avatar: some View {
        if let sender = item.sender {
            Button { showsSender = true } label: {
                ContactAvatar(accountID: item.id.accountID, address: sender.address, name: sender.name ?? "",
                              cache: mailbox.cache, accounts: mailbox.accountStore, size: avatarSize)
            }
            .buttonStyle(.borderless)
            .help("Show sender details")
            .accessibilityLabel("Show details for \(sender.name ?? sender.address)")
            .popover(isPresented: $showsSender, arrowEdge: .trailing) {
                SenderProfilePopover(accountID: item.id.accountID, address: sender.address,
                                     name: sender.name ?? sender.address, mailbox: mailbox)
            }
        } else {
            TernAvatar(name: "", size: avatarSize)
        }
    }

    private func senderLine(date: String) -> some View {
        HStack(spacing: Tokens.Space.s1_5) {
            // Preserve the shared avatar's image shape, transparency and size policy.
            avatar
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                Text(senderText)
                    .font(scaledFont(.body, weight: textWeight))
                    .lineLimit(1)
                    .help(senderDetails)
                if thread.messageCount > 1 {
                    Text("\(thread.messageCount)")
                        .font(scaledFont(.caption2).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Tokens.Space.s1)
                        .background(.primary.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                        .fixedSize()
                        .help("\(thread.messageCount) messages")
                }
                Spacer(minLength: Tokens.Space.s1)
                if mailbox.listPreferences.showsImportance, item.labels.contains(SystemLabel.important) {
                    Image(systemName: "exclamationmark").font(scaledFont(.caption1, weight: .semibold))
                        .foregroundStyle(Tokens.Status.important).accessibilityLabel("Important")
                }
                Button { mailbox.toggleListStar([item.id]) } label: {
                    Image(systemName: thread.isStarred ? "star.fill" : "star")
                        .font(scaledFont(.caption1))
                        .foregroundStyle(thread.isStarred ? Tokens.Status.star : Color.secondary)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .ternAnimation(value: thread.isStarred, duration: Tokens.Motion.fast)
                        .frame(width: Tokens.Space.s5, height: Tokens.Space.s5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .focused($starFocused)
                // Keep the action's space even while hidden, so hover never moves the date.
                .opacity(showsStar ? 1 : 0)
                .ternAnimation(value: showsStar, duration: Tokens.Motion.fast)
                .help(thread.isStarred ? "Remove Star" : "Star")
                .accessibilityLabel(thread.isStarred ? "Remove Star" : "Star")
                Text(date).font(scaledFont(.caption1, weight: textWeight).monospacedDigit())
                .foregroundStyle(thread.isUnread ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize()
                .help(thread.lastDate.formatted(date: .complete, time: .shortened))
            }
        }
    }

    private var subjectLine: some View {
        HStack(spacing: Tokens.Space.s1) {
            if item.labels.contains(SystemLabel.draft) {
                Text("Draft").font(scaledFont(.caption1, weight: .medium)).foregroundStyle(Tokens.Status.error)
            }
            Text(thread.subject.isEmpty ? AttributedString("No Subject") : mailbox.search.highlights.subject(thread.subject))
                .font(scaledFont(.callout, weight: textWeight))
                .foregroundStyle(thread.subject.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .help(thread.subject.isEmpty ? "No Subject" : thread.subject)
        }
    }

    @ViewBuilder private var previewLine: some View {
        if let wake = wakeTime {
            Label("Returns \(ThreadDate.wake(wake))", systemImage: "clock")
                .font(scaledFont(.caption1)).foregroundStyle(.secondary).lineLimit(1)
                .help("Returns \(ThreadDate.wake(wake))")
        } else if !thread.snippet.isEmpty {
            Text(mailbox.search.highlights.preview(thread.snippet)).font(scaledFont(.caption1)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func detailLine(labels: [LabelRecord]) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            if !labels.isEmpty {
                ViewThatFits(in: .horizontal) {
                    labelGroup(labels, visibleCount: min(2, labels.count)).fixedSize(horizontal: true, vertical: false)
                    if labels.count > 1 {
                        labelGroup(labels, visibleCount: 1).fixedSize(horizontal: true, vertical: false)
                    }
                    // A single long label can truncate while the overflow count remains visible.
                    labelGroup(labels, visibleCount: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let attachment = item.attachments.first {
                Label(attachment.filename, systemImage: attachmentSymbol(attachment.mimeType))
                    .font(scaledFont(.caption1))
                    .lineLimit(1).help(attachment.filename)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.attachments.count > 1 {
                    Text("+\(item.attachments.count - 1)")
                        .font(scaledFont(.caption1).monospacedDigit()).fixedSize()
                }
            } else {
                Spacer(minLength: 0)
            }
            if !labels.isEmpty, !item.attachments.isEmpty {
                Label("\(item.attachments.count)", systemImage: "paperclip")
                    .font(labelFont.monospacedDigit())
                    .fixedSize()
                    .help(item.attachments.map(\.filename).joined(separator: "\n"))
                    .accessibilityLabel(item.attachments.map(\.filename).joined(separator: ", "))
            }
            if showsAccount, let accountMark {
                HStack(spacing: Tokens.Space.s0_5) {
                    Circle().fill(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(accountColor))
                        .frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                    Text(accountMark).font(scaledFont(.caption2, weight: .medium))
                }
                .fixedSize()
                .help(accountDescription)
                .accessibilityLabel(accountDescription)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func labelGroup(_ labels: [LabelRecord], visibleCount: Int) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            ForEach(Array(labels.prefix(visibleCount)), id: \.id) { label in
                MailLabelBadge(label: label, font: labelFont)
            }
            if labels.count > visibleCount {
                Text("+\(labels.count - visibleCount)")
                    .font(labelFont.monospacedDigit())
                    .fixedSize()
                    .help(labels.dropFirst(visibleCount).map(\.title).joined(separator: ", "))
                    .accessibilityLabel(labels.dropFirst(visibleCount).map(\.title).joined(separator: ", "))
            }
        }
    }

    private var showsRecipients: Bool {
        [SystemLabel.sent, SystemLabel.draft].contains(mailbox.selectedLabelID ?? "") && !item.recipients.isEmpty
    }

    private var senderText: String {
        showsRecipients ? "To: " + item.recipientPresentation.compact : item.senderPresentation.compact
    }

    private var senderDetails: String {
        showsRecipients ? "To: " + item.recipientPresentation.full : item.senderPresentation.full
    }

    private func accessibilitySummary(labels: [LabelRecord], date: String) -> String {
        let account = mailbox.listMixesAccounts ? accountDescription : nil
        return MessageListRow.accessibilitySummary(
            unread: thread.isUnread, sender: senderDetails, subject: thread.subject,
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
        .padding(.vertical, Tokens.Space.s0_5)
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
    @Environment(\.openWindow) private var openWindow

    private var items: [MessageListItem] { mailbox.listItems.filter { rows.contains($0.id) } }
    private var state: MailContextState { MailContextState(items: items) }
    private var singleAccount: Bool { Set(rows.map(\.accountID)).count == 1 }

    var body: some View {
        Group {
            if !rows.isEmpty {
                composeItems
                MailContextTriageItems(mailbox: mailbox, rows: rows, state: state, unsnoozes: mailbox.showsSnoozed)
                Divider()
                let allRead = mailbox.allListRead(rows)
                Button(allRead ? "Mark as Unread" : "Mark as Read", systemImage: allRead ? "envelope.badge" : "envelope.open") {
                    mailbox.toggleListRead(rows)
                }
                let allStarred = mailbox.allListStarred(rows)
                Button(allStarred ? "Remove Star" : "Star", systemImage: allStarred ? "star.fill" : "star") { mailbox.toggleListStar(rows) }
                Divider()
                Button("Edit Labels…", systemImage: "tag") { mailbox.showEditLabels(forRows: rows) }
                    .disabled(!singleAccount)
                Button("Move to…", systemImage: "folder") { mailbox.showMoveTo(forRows: rows) }
                    .disabled(!singleAccount)
                if mailbox.snoozeKeeper != nil, !state.containsDrafts, state.permanentDeletionLabel == nil {
                    Menu("Snooze", systemImage: "clock") {
                        SnoozeMenuItems(onSnooze: { mailbox.snoozeRows(rows, until: $0) },
                                        onChooseDate: { mailbox.showSnoozeDate(forRows: rows) })
                    }
                }
                if mailbox.showsSnoozed {
                    Button("Unsnooze", systemImage: "clock.arrow.circlepath") { mailbox.unsnoozeRows(rows) }
                }
                if rows.count == 1, let row = rows.first {
                    Divider()
                    linkItems(for: row)
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var composeItems: some View {
        if rows.count == 1, let item = items.first {
            let messages = item.messages.sorted { $0.message.date < $1.message.date }
            if let draft = messages.last(where: { $0.labels.contains(SystemLabel.draft) }) {
                Button("Edit Draft", systemImage: "pencil") {
                    Task {
                        guard let id = await mailbox.startCompose(.editDraft(messageID: draft.message.id, accountID: item.id.accountID)) else { return }
                        openWindow(id: ComposeWindow.sceneID, value: id)
                    }
                }
            }
            if let entry = messages.last(where: { !$0.labels.contains(SystemLabel.draft) }) {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(.reply, to: entry.message) }
                Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { reply(.replyAll, to: entry.message) }
                Button("Forward", systemImage: "arrowshape.turn.up.right") { reply(.forward, to: entry.message) }
                Button("Forward as Attachment", systemImage: "paperclip") {
                    Task {
                        guard let id = await mailbox.startForwardingAttachment(messageID: entry.message.id, accountID: entry.message.accountID) else { return }
                        openWindow(id: ComposeWindow.sceneID, value: id)
                    }
                }
            }
            if !messages.isEmpty { Divider() }
        }
    }

    @ViewBuilder private func linkItems(for row: MailListRowID) -> some View {
        let link = mailbox.conversationLink(for: row)
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { mailbox.requestConversationWindow(for: row) }
        if let url = link.ternURL {
            Button("Copy Link", systemImage: "link") { NSPasteboard.general.replaceContents(with: url.absoluteString) }
        }
        if let email = mailbox.account(id: row.accountID)?.account.email, let url = link.gmailURL(email: email) {
            Button("Open in Gmail", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
            Button("Copy Gmail Link", systemImage: "link") { NSPasteboard.general.replaceContents(with: url.absoluteString) }
        }
    }

    private func reply(_ kind: ReplyKind, to message: MessageRecord) {
        Task {
            guard let id = await mailbox.requestReply(kind, messageID: message.id, accountID: message.accountID, selectedText: nil) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }
}
