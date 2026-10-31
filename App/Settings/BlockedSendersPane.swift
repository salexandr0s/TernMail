import GmailAPI
import MessageContent
import SwiftUI

struct BlockedSendersPane: View {
    @Bindable var model: SettingsModel
    let header: GmailSettingsHeader
    @State private var unblocking: GmailFilter?

    var body: some View {
        SettingsPage {
            header
            Section {
                if blocked.isEmpty {
                    Text("This account has no sender-blocking filters.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(blocked.enumerated()), id: \.offset) { _, filter in
                        LabeledContent {
                            Button("Unblock…") { unblocking = filter }
                                .controlSize(.small)
                                .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
                        } label: {
                            Text(filter.criteria.from ?? "")
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text(blocked.isEmpty ? "Blocked senders" : "\(blocked.count) blocked \(blocked.count == 1 ? "sender" : "senders")")
            } footer: {
                Text("Blocked senders use Gmail filters that send new messages to Trash. Earlier messages stay where they are.")
            }
        }
        .ternConfirm("Unblock this sender?", item: $unblocking, actionTitle: "Unblock",
                     message: "New messages from this sender arrive in your Inbox again. You can undo this change.") { filter in
            Task { await model.deleteFilter(filter) }
        }
    }

    private var blocked: [GmailFilter] {
        model.filters.filter { SenderFilterRules.blockedAddress($0) != nil }
    }
}
