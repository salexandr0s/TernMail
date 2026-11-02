import MailStore
import SwiftUI

/// Drafts and sends that haven't reached Gmail. Opening one reopens its compose window.
struct OutboxView: View {
    let mailbox: MailboxModel
    @FocusState.Binding var listFocused: Bool

    @State private var selection: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            messages
        }
        .background(Tokens.Surface.primary)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            TernPageHeader(title: "Outbox", subtitle: messageCount)
            if attentionCount > 0 {
                Label(attentionCount == 1 ? "1 message needs attention" : "\(attentionCount.formatted()) messages need attention",
                      systemImage: "exclamationmark.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Tokens.Status.error)
            } else if retryCount > 0 {
                Label("Tern will retry when Gmail is available.", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Tokens.Workspace.pageGutter)
        .padding(.vertical, Tokens.Space.s5)
        .accessibilityIdentifier("outbox.heading")
    }

    private var messages: some View {
        List(selection: $selection) {
            ForEach(mailbox.selectedOutbox) { activity in
                OutboxRow(activity: activity, onOpen: { open(activity.id) },
                    onCancelSend: Self.canUndoSend(activity) ? { undoSend(activity.id) } : nil)
                    .tag(activity.id)
            }
        }
        .listStyle(.inset)
        .focused($listFocused)
        .overlay {
            if mailbox.selectedOutbox.isEmpty {
                TernEmptyState(
                    title: "Outbox Is Empty",
                    systemImage: "tray.and.arrow.up",
                    message: "Messages waiting to send appear here."
                )
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Open", systemImage: "arrow.up.forward.square") { open(id) }
                    .labelStyle(.titleAndIcon)
                if let activity = mailbox.selectedOutbox.first(where: { $0.id == id }), Self.canUndoSend(activity) {
                    Button("Cancel Send", systemImage: "arrow.uturn.backward") { undoSend(id) }
                        .labelStyle(.titleAndIcon)
                }
            }
        } primaryAction: { ids in
            ids.forEach(open)
        }
        .onChange(of: mailbox.selectedOutbox.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private var messageCount: String {
        let count = mailbox.selectedOutbox.count
        return count == 1 ? "1 message waiting for Gmail" : "\(count.formatted()) messages waiting for Gmail"
    }

    private var attentionCount: Int {
        mailbox.selectedOutbox.count { $0.draft.sendError != nil }
    }

    private var retryCount: Int {
        mailbox.selectedOutbox.count { $0.isWaitingToRetry }
    }

    /// A queued send whose delivery has never been requested, including a
    /// failed draft lookup or upload before delivery.
    static func canUndoSend(_ activity: DraftActivity) -> Bool {
        activity.canCancelSend
    }

    private func open(_ id: String) {
        openWindow(id: ComposeWindow.sceneID, value: id)
    }

    private func undoSend(_ id: String) {
        Task {
            if await mailbox.undoSend(id) { open(id) }
        }
    }
}
