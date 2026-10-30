import GmailAPI
import MessageContent
import SwiftUI

struct BlockedSendersPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Blocked senders use Gmail filters that send new messages to Trash. Earlier messages stay where they are.")
                .font(.callout).foregroundStyle(.secondary)
            if blocked.isEmpty {
                ContentUnavailableView("No blocked senders", systemImage: "person.crop.circle.badge.checkmark")
            } else {
                List(Array(blocked.enumerated()), id: \.offset) { _, filter in
                    HStack {
                        Text(filter.criteria.from ?? "").textSelection(.enabled)
                        Spacer()
                        Button("Unblock") { Task { await model.deleteFilter(filter) } }
                            .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
                    }
                }
            }
        }
    }

    private var blocked: [GmailFilter] {
        model.filters.filter { SenderFilterRules.blockedAddress($0) != nil }
    }
}
