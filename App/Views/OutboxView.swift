import MailStore
import SwiftUI

/// Drafts and sends that haven't reached Gmail. Opening one reopens its compose window.
struct OutboxView: View {
    let mailbox: MailboxModel
    @FocusState.Binding var listFocused: Bool

    @State private var selection: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        List(selection: $selection) {
            ForEach(mailbox.selectedOutbox) { activity in
                OutboxRow(activity: activity)
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
                    Button("Undo Send", systemImage: "arrow.uturn.backward") { undoSend(id) }
                        .labelStyle(.titleAndIcon)
                }
            }
        } primaryAction: { ids in
            ids.forEach(open)
        }
        .onChange(of: mailbox.selectedOutbox.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .background(Tokens.Surface.primary)
    }

    /// A send still waiting out its delay, which hasn't tried Gmail yet.
    static func canUndoSend(_ activity: DraftActivity) -> Bool {
        activity.isSending && activity.rows.contains { $0.kind == .sendDraft && $0.state == .queued && $0.attempts == 0 }
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

private struct OutboxRow: View {
    let activity: DraftActivity

    var body: some View {
        let draft = activity.draft
        let status = Self.status(activity)
        VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                Text(recipients)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .help(recipients)
                Spacer(minLength: Tokens.Space.s2)
                Text(ThreadDate.short(draft.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(draft.subject.isEmpty ? "No Subject" : draft.subject)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .help(draft.subject)
            TernBadge(text: status.title, systemImage: status.icon, tint: status.tint)
            if let detail = status.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(detail)
            }
        }
        .padding(.vertical, Tokens.Space.s2)
        .accessibilityElement(children: .combine)
    }

    private var recipients: String {
        let draft = activity.draft
        let names = (draft.to + draft.cc + draft.bcc).map { address in
            address.name.flatMap { $0.isEmpty ? nil : $0 } ?? address.address
        }
        return names.isEmpty ? "No Recipients" : names.joined(separator: ", ")
    }

    private static func status(_ activity: DraftActivity) -> (title: String, detail: String?, icon: String, tint: Color) {
        if let error = activity.draft.sendError {
            return ("Not Sent", error, "exclamationmark.triangle", Tokens.Status.error)
        }
        if activity.isWaitingToRetry {
            return ("Retrying", "Can't reach Gmail. Tern will keep trying.", "arrow.clockwise", Tokens.Status.warning)
        }
        if activity.rows.contains(where: { $0.kind == .sendDraft && $0.state == .sending }) {
            return ("Sending…", nil, "paperplane", .accentColor)
        }
        return ("Waiting to Send", nil, "clock", .secondary)
    }
}
