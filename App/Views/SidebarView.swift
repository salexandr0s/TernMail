import MailStore
import SwiftUI

struct SidebarView: View {
    @Bindable var mailbox: MailboxModel

    var body: some View {
        List(selection: $mailbox.selectedLabelID) {
            Section("Mailboxes") {
                ForEach(SystemMailbox.all) { box in
                    Label(box.title, systemImage: box.systemImage)
                        .badge(box.id == SystemLabel.inbox ? mailbox.label(id: box.id)?.threadsUnread ?? 0 : 0)
                        .tag(box.id as String?)
                }
            }
            if !mailbox.userLabels.isEmpty {
                Section("Labels") {
                    ForEach(mailbox.userLabels, id: \.id) { label in
                        Label {
                            Text(label.name)
                        } icon: {
                            Image(systemName: "tag")
                                .foregroundStyle(Color(gmailHex: label.backgroundColor) ?? .secondary)
                        }
                        .badge(label.threadsUnread ?? 0)
                        .tag(label.id as String?)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            SyncStatusView(mailbox: mailbox)
        }
    }
}

private struct SyncStatusView: View {
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            switch mailbox.syncStatus {
            case .syncing:
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.mini)
                    Text("Checking for mail…")
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { mailbox.syncNow() }
                    .buttonStyle(.link)
            case .idle:
                if let date = mailbox.lastSyncedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated \(date.formatted(.relative(presentation: .named)))")
                    }
                }
            }
            Text(mailbox.account.email)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(mailbox.account.email)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s3)
    }
}

extension Color {
    /// Gmail label colors arrive as "#rrggbb".
    init?(gmailHex hex: String?) {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
