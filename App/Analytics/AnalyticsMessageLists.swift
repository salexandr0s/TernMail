import MailStore
import MessageContent
import SwiftUI

struct AnalyticsCorrespondentsView: View {
    let correspondents: [MailAnalyticsCorrespondent]
    let selectedAccountID: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Frequent contacts").font(.headline)
            if correspondents.isEmpty {
                Text("Contacts appear here when mail is available for this period.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(correspondents.prefix(10)) { contact in
                    Button {
                        openWindow(id: MailAnalyticsWindow.sceneID,
                            value: MailAnalyticsRoute(accountID: selectedAccountID, address: contact.address, name: contact.name))
                    } label: {
                        HStack(spacing: Tokens.Space.s3) {
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(contact.name ?? contact.address).font(.callout.weight(.medium))
                                    .lineLimit(1).truncationMode(.middle)
                                if contact.name != nil {
                                    Text(contact.address).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: Tokens.Space.s3)
                            VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                                Text("\(contact.receivedCount.formatted()) received").font(.caption)
                                Text("\(contact.sentCount.formatted()) sent").font(.caption).foregroundStyle(.secondary)
                            }
                            .monospacedDigit().fixedSize()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, Tokens.Space.s2)
                        .padding(.horizontal, Tokens.Space.s2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .ternHover()
                    .help("View analytics for \(contact.address)")
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }
}

struct AnalyticsRecentMessagesView: View {
    let messages: [MailAnalyticsMessage]
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Recent emails").font(.headline)
            if messages.isEmpty {
                Text("No messages in this period.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(messages.prefix(10)) { message in
                    AnalyticsConversationButton(link: .init(accountID: message.accountID,
                        threadID: message.threadID, messageID: message.messageID), mailbox: mailbox) {
                        HStack(alignment: .top, spacing: Tokens.Space.s3) {
                            Image(systemName: message.direction == .sent ? "arrow.up.right" : "arrow.down.left")
                                .foregroundStyle(.secondary)
                                .frame(width: Tokens.Control.icon)
                                .accessibilityLabel(message.direction == .sent ? "Sent" : "Received")
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(message.subject.isEmpty ? "No subject" : message.subject)
                                    .font(.callout.weight(.medium)).lineLimit(2)
                                Text(message.sender).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: Tokens.Space.s2)
                            Text(message.date, format: .dateTime.month(.abbreviated).day())
                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        .padding(.vertical, Tokens.Space.s2)
                        .padding(.horizontal, Tokens.Space.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .ternHover()
                    .help("Open email · \(message.date.formatted(date: .complete, time: .shortened))")
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }
}

struct AnalyticsReceiptsView: View {
    let receipts: [ReadReceiptStatus]
    let error: String?
    let contactAddress: String?
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Read receipts").font(.headline)
                Spacer(minLength: 0)
                Text("All history").font(.caption).foregroundStyle(.secondary)
            }
            Text("Request a receipt from the send options when composing. Receipts depend on the recipient's email app and settings; no receipt does not mean unread.")
                .font(.callout).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(Tokens.Status.error)
            } else if receipts.isEmpty {
                Label("No receipt requests yet", systemImage: "envelope.badge")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(receipts.prefix(10)) { receipt in
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        HStack(alignment: .firstTextBaseline) {
                            if let threadID = receipt.threadID {
                                AnalyticsConversationButton(link: .init(accountID: receipt.accountID,
                                    threadID: threadID, messageID: receipt.messageID), mailbox: mailbox) {
                                    Text(receipt.subject.isEmpty ? "No subject" : receipt.subject)
                                }
                                .buttonStyle(.borderless).lineLimit(2)
                            } else {
                                Text(receipt.subject.isEmpty ? "No subject" : receipt.subject).lineLimit(2)
                            }
                            Spacer(minLength: Tokens.Space.s2)
                            Text(receipt.sentAt, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        .font(.callout.weight(.medium))
                        ForEach(recipients(for: receipt)) { recipient in
                            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                                Image(systemName: recipient.receivedAt == nil ? "clock" : "checkmark.circle")
                                    .foregroundStyle(recipient.receivedAt == nil ? Color.secondary : Tokens.Status.success)
                                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                                    Text(recipient.address).textSelection(.enabled)
                                    if let receivedAt = recipient.receivedAt {
                                        Text("Read receipt received \(receivedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("No receipt yet").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .font(.caption)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.vertical, Tokens.Space.s2)
                }
                Text("Times show when the receipt arrived, not when the email was opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }

    private func recipients(for receipt: ReadReceiptStatus) -> [ReadReceiptRecipientStatus] {
        guard let contactAddress else { return receipt.recipients }
        return receipt.recipients.filter { $0.address.lowercased() == contactAddress.lowercased() }
    }
}
