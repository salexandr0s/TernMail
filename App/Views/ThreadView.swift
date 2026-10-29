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
                        Text(detail.thread.subject.isEmpty ? "No Subject" : detail.thread.subject)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(detail.messages) { message in
                            MessageView(
                                message: message,
                                blocker: blocker,
                                isExpanded: expanded.contains(message.id),
                                mailbox: mailbox,
                                compose: compose
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

private struct MessageView: View {
    let message: MessageDetail
    let blocker: WKContentRuleList?
    let isExpanded: Bool
    let mailbox: MailboxModel
    let compose: (MailboxModel.ComposeStart) -> Void
    let onToggle: () -> Void

    @State private var rendered: RenderedMessage?
    @State private var hasNoText = false
    @State private var height: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Button(action: onToggle) {
                header
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses this message" : "Expands this message")

            if isExpanded {
                content
                if !message.attachments.isEmpty {
                    ReceivedAttachmentsView(attachments: message.attachments, mailbox: mailbox)
                }
                actions
            }
        }
        .task(id: message.body?.fetchedAt) {
            await render()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                Text(senderName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if isExpanded {
                    Text("To: \(message.record.recipients)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let cc = message.record.cc, !cc.isEmpty {
                        Text("Cc: \(cc)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(message.record.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.Space.s2)
            if message.isStarred {
                Image(systemName: "star.fill")
                    .imageScale(.small)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Starred")
            }
            Text(message.record.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help(message.record.sender)
    }

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

    private var actions: some View {
        let accountID = message.record.accountID
        return HStack(spacing: Tokens.Space.s2) {
            if message.labels.contains(SystemLabel.draft) {
                Button("Edit Draft", systemImage: "pencil") {
                    compose(.editDraft(messageID: message.id, accountID: accountID))
                }
            } else {
                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                    compose(.reply(.reply, messageID: message.id, accountID: accountID))
                }
                Button("Reply All", systemImage: "arrowshape.turn.up.left.2") {
                    compose(.reply(.replyAll, messageID: message.id, accountID: accountID))
                }
                Button("Forward", systemImage: "arrowshape.turn.up.right") {
                    compose(.reply(.forward, messageID: message.id, accountID: accountID))
                }
            }
        }
        .controlSize(.small)
    }

    private var senderName: String {
        let sender = message.record.sender
        guard let open = sender.firstIndex(of: "<") else { return sender }
        let name = sender[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        return name.isEmpty ? sender : name
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
