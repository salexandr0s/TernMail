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
                    Label {
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text("No sender-blocking filters")
                            Text("Filters that block individual senders appear here.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(blocked.enumerated()), id: \.offset) { _, filter in
                        LabeledContent {
                            Button("Unblock…") { unblocking = filter }
                                .fixedSize()
                                .accessibilityLabel("Unblock \(filter.criteria.from ?? "sender")")
                                .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                    Text(filter.criteria.from ?? "")
                                        .font(.body.weight(.medium))
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                        .help(filter.criteria.from ?? "")
                                    Text(filter.id == nil ? "Waiting for Gmail" : "New messages go to Trash")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: "hand.raised")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, Tokens.Space.s1)
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
