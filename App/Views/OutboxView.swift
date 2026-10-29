import MailStore
import SwiftUI

/// Drafts and sends that haven't reached Gmail. Opening one reopens its compose window.
struct OutboxView: View {
    let mailbox: MailboxModel

    @State private var selection: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if mailbox.outbox.isEmpty {
                ContentUnavailableView(
                    "Outbox Is Empty",
                    systemImage: "tray.and.arrow.up",
                    description: Text("Gmail has every message you sent.")
                )
            } else {
                List(selection: $selection) {
                    ForEach(mailbox.outbox) { activity in
                        OutboxRow(activity: activity)
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        Button("Open") { open(id) }
                        if let activity = mailbox.outbox.first(where: { $0.id == id }), Self.canUndoSend(activity) {
                            Button("Undo Send") { undoSend(id) }
                        }
                    }
                } primaryAction: { ids in
                    ids.forEach(open)
                }
            }
        }
        .navigationTitle("Outbox")
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
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                Text(recipients)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Space.s2)
                Text(ThreadDate.short(draft.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(draft.subject.isEmpty ? "No Subject" : draft.subject)
                .lineLimit(1)
            Label {
                Text(status.text)
            } icon: {
                Image(systemName: status.isError ? "exclamationmark.triangle" : "clock")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .padding(.vertical, Tokens.Space.s1)
        .accessibilityElement(children: .combine)
    }

    private var recipients: String {
        let draft = activity.draft
        let names = (draft.to + draft.cc + draft.bcc).map { address in
            address.name.flatMap { $0.isEmpty ? nil : $0 } ?? address.address
        }
        return names.isEmpty ? "No Recipients" : names.joined(separator: ", ")
    }

    private static func status(_ activity: DraftActivity) -> (text: String, isError: Bool) {
        if let error = activity.draft.sendError { return (error, true) }
        if activity.isWaitingToRetry { return ("Can't reach Gmail. Tern will keep trying.", false) }
        if activity.rows.contains(where: { $0.kind == .sendDraft && $0.state == .sending }) { return ("Sending…", false) }
        return ("Waiting to send", false)
    }
}
