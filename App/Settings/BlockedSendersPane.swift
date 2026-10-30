import GmailAPI
import MessageContent
import SwiftUI

struct BlockedSendersPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            SettingsNote("Blocked senders use Gmail filters that send new messages to Trash. Earlier messages stay where they are.", systemImage: "person.crop.circle.badge.xmark")
            if blocked.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("No blocked senders").font(.body.weight(.medium))
                    Text("This account has no sender-blocking filters.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } else {
                Text("\(blocked.count) blocked \(blocked.count == 1 ? "sender" : "senders")")
                    .font(.body.weight(.medium))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(blocked.enumerated()), id: \.offset) { index, filter in
                            if index > 0 {
                                Divider().padding(.horizontal, Tokens.Space.s3)
                            }
                            HStack(spacing: Tokens.Space.s3) {
                                Text(filter.criteria.from ?? "")
                                    .font(.body.weight(.medium))
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer(minLength: Tokens.Space.s3)
                                Button("Unblock") { Task { await model.deleteFilter(filter) } }
                                    .controlSize(.small)
                                    .disabled(!model.canEdit || filter.id == nil || model.pendingCount > 0)
                            }
                            .padding(.horizontal, Tokens.Space.s3)
                            .padding(.vertical, Tokens.Space.s2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsSurface()
                }
            }
        }
    }

    private var blocked: [GmailFilter] {
        model.filters.filter { SenderFilterRules.blockedAddress($0) != nil }
    }
}
