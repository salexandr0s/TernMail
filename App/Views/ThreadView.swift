import MailStore
import MessageContent
import SwiftUI
import WebKit

struct ThreadView: View {
    let key: ThreadKey
    let mailbox: MailboxModel

    @State private var detail: ThreadDetail?
    @State private var expanded: Set<String> = []
    @State private var initializedExpansion = false
    @State private var blocker: WKContentRuleList?
    @State private var blockerReady = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let detail, blockerReady {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                        ThreadHeading(detail: detail, key: key, mailbox: mailbox)
                        ForEach(detail.messages) { message in
                            MessageView(
                                message: message,
                                blocker: blocker,
                                isExpanded: expanded.contains(message.id),
                                isThreadStarred: detail.thread.isStarred,
                                mailbox: mailbox,
                                compose: compose,
                                onToggleStar: { mailbox.perform(detail.thread.isStarred ? .unstar : .star, on: [key]) }
                            ) {
                                if expanded.contains(message.id) {
                                    expanded.remove(message.id)
                                } else {
                                    expanded.insert(message.id)
                                }
                            }
                            if message.id != detail.messages.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(Tokens.Space.s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            blocker = await RemoteContentBlocker.ruleList()
            blockerReady = true
        }
        .task(id: key) {
            var loading: Task<Void, Never>?
            defer { loading?.cancel() }
            do {
                for try await detail in mailbox.threadDetail(key) {
                    guard !Task.isCancelled else { return }
                    if !initializedExpansion, let last = detail?.messages.last {
                        // Older messages start collapsed; unread ones stay open.
                        expanded = Set(detail?.messages.filter(\.isUnread).map(\.id) ?? []).union([last.id])
                        initializedExpansion = true
                    }
                    self.detail = detail
                    // Capture initial unread expansion before opening marks read.
                    if loading == nil, detail != nil {
                        loading = Task { await mailbox.open(key) }
                    }
                }
            } catch {
                self.detail = nil
            }
        }
    }

    /// Opens a compose window once its draft exists. A failure shows as a notice.
    private func compose(_ start: MailboxModel.ComposeStart) {
        Task {
            guard let id = await mailbox.startCompose(start) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }
}

/// The subject, followed by a chip for the Inbox and each user label the
/// conversation is in. Removing the Inbox chip archives the conversation.
private struct ThreadHeading: View {
    let detail: ThreadDetail
    let key: ThreadKey
    let mailbox: MailboxModel

    var body: some View {
        FlowLayout(spacing: Tokens.Space.s2) {
            Text(detail.thread.subject.isEmpty ? "No Subject" : detail.thread.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(chips, id: \.id) { label in
                if label.id == SystemLabel.inbox {
                    LabelChip(name: "Inbox", colors: nil, removeHelp: "Archive") {
                        mailbox.perform(.archive, on: [key])
                    }
                } else {
                    LabelChip(name: label.name, colors: colors(of: label), removeHelp: "Remove Label") {
                        mailbox.removeLabel(label.id, from: key)
                    }
                }
            }
        }
    }

    /// The Inbox, then user labels by name.
    private var chips: [LabelRecord] {
        let applied = detail.messages.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
        let labels = mailbox.account(id: key.accountID)?.labels ?? []
        let inbox = labels.filter { $0.id == SystemLabel.inbox && applied.contains($0.id) }
        let user = labels
            .filter { !$0.isSystem && applied.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return inbox + user
    }

    private func colors(of label: LabelRecord) -> LabelChip.Colors? {
        guard let background = Color(gmailHex: label.backgroundColor) else { return nil }
        return LabelChip.Colors(background: background, text: Color(gmailHex: label.textColor) ?? .primary)
    }
}

private struct LabelChip: View {
    struct Colors {
        let background: Color
        let text: Color
    }

    let name: String
    /// Gmail's label colors. Without them the chip is outlined.
    let colors: Colors?
    let removeHelp: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            Text(name)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help(removeHelp)
            .accessibilityLabel("\(removeHelp): \(name)")
        }
        .font(.callout)
        .foregroundStyle(colors?.text ?? .primary)
        .padding(.horizontal, Tokens.Space.s1_5)
        .padding(.vertical, Tokens.Space.s0_5)
        .background {
            let shape = RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            if let colors {
                shape.fill(colors.background)
            } else {
                shape.strokeBorder(.secondary)
            }
        }
    }
}

/// Places views left to right and starts a new row when the next one
/// doesn't fit. Each row's views are centered vertically.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                let origin = CGPoint(x: x, y: y + (row.height - item.size.height) / 2)
                subviews[item.index].place(at: origin, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

private struct MessageView: View {
    let message: MessageDetail
    let blocker: WKContentRuleList?
    let isExpanded: Bool
    /// Stars belong to the conversation, as the list and the toolbar treat them.
    let isThreadStarred: Bool
    let mailbox: MailboxModel
    let compose: (MailboxModel.ComposeStart) -> Void
    let onToggleStar: () -> Void
    let onToggle: () -> Void

    @State private var rendered: RenderedMessage?
    @State private var hasNoText = false
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            header

            if isExpanded {
                content
                if !message.attachments.isEmpty {
                    ReceivedAttachmentsView(attachments: message.attachments, mailbox: mailbox)
                }
            }
        }
        .task(id: message.body?.fetchedAt) {
            await render()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: Tokens.Space.s3) {
                    SenderAvatar(name: senderName, address: senderAddress)
                    VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                        Text(senderName)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        if isExpanded {
                            recipients("To:", message.record.recipients)
                            if let cc = message.record.cc, !cc.isEmpty {
                                recipients("Cc:", cc)
                            }
                        } else {
                            Text(message.record.snippet)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Tokens.Space.s2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(message.record.sender)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses this message" : "Expands this message")

            VStack(alignment: .trailing, spacing: Tokens.Space.s1_5) {
                Text(Self.dateFormatter.string(from: message.record.date))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isExpanded {
                    actions
                } else if message.isStarred {
                    Image(systemName: "star.fill")
                        .imageScale(.small)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel("Starred")
                }
            }
            .fixedSize()
        }
    }

    private func recipients(_ title: String, _ header: String) -> some View {
        let names = EmailAddress.parseList(header).map { $0.name ?? $0.address }
        let list = names.isEmpty ? header : names.formatted(.list(type: .and, width: .narrow))
        return Text("\(title) \(Text(list).foregroundStyle(.secondary))")
            .font(.callout)
            .lineLimit(2)
    }

    /// Star, the likelier reply, and the other replies in a menu.
    @ViewBuilder
    private var actions: some View {
        let accountID = message.record.accountID
        HStack(spacing: Tokens.Space.s2) {
            if message.labels.contains(SystemLabel.draft) {
                Button("Edit Draft", systemImage: "pencil") {
                    compose(.editDraft(messageID: message.id, accountID: accountID))
                }
                .help("Edit Draft")
            } else {
                Button(action: onToggleStar) {
                    Label(isThreadStarred ? "Remove Star" : "Star", systemImage: isThreadStarred ? "star.fill" : "star")
                        .foregroundStyle(isThreadStarred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                }
                .help(isThreadStarred ? "Remove Star" : "Star")

                let kind = primaryReply
                Button(kind == .replyAll ? "Reply All" : "Reply", systemImage: Self.symbol(kind)) {
                    compose(.reply(kind, messageID: message.id, accountID: accountID))
                }
                .help(kind == .replyAll ? "Reply All" : "Reply")

                Menu {
                    Button("Reply", systemImage: Self.symbol(.reply)) {
                        compose(.reply(.reply, messageID: message.id, accountID: accountID))
                    }
                    Button("Reply All", systemImage: Self.symbol(.replyAll)) {
                        compose(.reply(.replyAll, messageID: message.id, accountID: accountID))
                    }
                    Button("Forward", systemImage: Self.symbol(.forward)) {
                        compose(.reply(.forward, messageID: message.id, accountID: accountID))
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .foregroundStyle(.secondary)
    }

    /// Reply All when the message went to someone besides its sender and
    /// this account, otherwise Reply.
    private var primaryReply: ReplyKind {
        let own = mailbox.account(id: message.record.accountID)?.account.email.lowercased()
        let sender = senderAddress.lowercased()
        let others = EmailAddress.parseList([message.record.recipients, message.record.cc ?? ""].joined(separator: ","))
            .map(\.normalized)
            .filter { $0 != own && $0 != sender }
        return others.isEmpty ? .reply : .replyAll
    }

    private static func symbol(_ kind: ReplyKind) -> String {
        switch kind {
        case .reply: "arrowshape.turn.up.left"
        case .replyAll: "arrowshape.turn.up.left.2"
        case .forward: "arrowshape.turn.up.right"
        }
    }

    /// "Today at 10:35", "Yesterday at 18:02", or the date and time.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    @ViewBuilder
    private var content: some View {
        if let rendered {
            if rendered.blockedRemoteContent > 0 {
                Label("Remote content blocked to protect your privacy", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            MessageWebView(html: rendered.html, blocker: blocker, height: $height)
                .frame(height: max(height, Tokens.Space.s8))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .accessibilityLabel("Message from \(senderName)")
        } else if hasNoText {
            Text("This message has no text.")
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var senderName: String {
        let sender = message.record.sender
        guard let open = sender.firstIndex(of: "<") else { return sender }
        let name = sender[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        return name.isEmpty ? sender : name
    }

    private var senderAddress: String {
        EmailAddress.parseList(message.record.sender).first?.address ?? message.record.sender
    }

    /// Sanitizing can take a moment on large mail, so it runs off the main actor.
    /// Without the rule list that blocks remote loads, only text is shown.
    private func render() async {
        guard let body = message.body else { return }
        let extracted = ExtractedBody(html: body.html, plainText: body.plainText)
        let textOnly = blocker == nil
        let result = await Task.detached(priority: .userInitiated) {
            textOnly ? MessageDocument.renderText(extracted) : MessageDocument.render(extracted)
        }.value
        rendered = result
        hasNoText = result == nil
    }
}

/// The sender's initials on a color chosen from their address, so a
/// sender keeps one color across conversations.
private struct SenderAvatar: View {
    let name: String
    let address: String

    var body: some View {
        Text(initials)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: Tokens.Space.s8, height: Tokens.Space.s8)
            .background(Circle().fill(color.gradient))
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let picked = words.count > 1 ? [words[0], words[words.count - 1]] : words
        let letters = picked.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var color: Color {
        let palette = AccountAppearance.palette
        // A fixed sum rather than `hashValue`, which changes on every launch.
        let sum = address.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}
