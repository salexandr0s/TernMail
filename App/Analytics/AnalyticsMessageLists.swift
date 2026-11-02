import MailStore
import MessageContent
import SwiftUI

struct AnalyticsCorrespondentsView: View {
    let correspondents: [MailAnalyticsCorrespondent]
    let selectedAccountID: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            AnalyticsListHeading(title: "Frequent contacts", count: min(correspondents.count, 10))
            if correspondents.isEmpty {
                Text("Contacts appear here when mail is available for this period.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(correspondents.prefix(10)) { contact in
                        Button {
                            openWindow(id: MailAnalyticsWindow.sceneID,
                                value: MailAnalyticsRoute(accountID: selectedAccountID, address: contact.address, name: contact.name))
                        } label: {
                            HStack(spacing: Tokens.Space.s3) {
                                Text(ContactAvatar.initials(name: contact.name ?? "", address: contact.address))
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(width: Tokens.Analytics.symbolSize, height: Tokens.Analytics.symbolSize)
                                    .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
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
                                    Text("^[\(contact.totalCount) email](inflect: true)").font(.callout.weight(.medium))
                                    HStack(spacing: Tokens.Space.s2) {
                                        Label {
                                            Text(contact.receivedCount.formatted()).foregroundStyle(.secondary)
                                        } icon: {
                                            Image(systemName: "arrow.down.left").foregroundStyle(Tokens.Analytics.received)
                                        }
                                            .accessibilityLabel("\(contact.receivedCount) received")
                                        Label {
                                            Text(contact.sentCount.formatted()).foregroundStyle(.secondary)
                                        } icon: {
                                            Image(systemName: "arrow.up.right").foregroundStyle(Tokens.Analytics.sent)
                                        }
                                            .accessibilityLabel("\(contact.sentCount) sent")
                                    }
                                    .font(.caption)
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
                        .help("View analytics for \(contact.address)\nLast email \(contact.lastContactAt.formatted(date: .complete, time: .shortened))")
                        if contact.id != correspondents.prefix(10).last?.id {
                            Divider().padding(.leading, Tokens.Analytics.symbolSize + Tokens.Space.s3 + Tokens.Space.s2)
                        }
                    }
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }
}

struct AnalyticsRecentMessagesView: View {
    let messages: [MailAnalyticsMessage]
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            AnalyticsListHeading(title: "Recent emails", count: min(messages.count, 10))
            if messages.isEmpty {
                Text("No messages in this period.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(messages.prefix(10)) { message in
                        AnalyticsConversationButton(link: .init(accountID: message.accountID,
                            threadID: message.threadID, messageID: message.messageID), mailbox: mailbox) {
                            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                                Image(systemName: message.direction == .sent ? "arrow.up.right" : "arrow.down.left")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(message.direction == .sent ? Tokens.Analytics.sent : Tokens.Analytics.received)
                                    .frame(width: Tokens.Analytics.symbolSize, height: Tokens.Analytics.symbolSize)
                                    .background((message.direction == .sent ? Tokens.Analytics.sent : Tokens.Analytics.received)
                                        .opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                                    .accessibilityLabel(message.direction == .sent ? "Sent" : "Received")
                                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                    Text(message.subject.isEmpty ? "No subject" : message.subject)
                                        .font(.callout.weight(.medium)).lineLimit(2)
                                    Text(message.sender).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: Tokens.Space.s2)
                                VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                                    Text(message.date, format: .dateTime.month(.abbreviated).day())
                                        .foregroundStyle(.secondary)
                                    Text(message.direction == .sent ? "Sent" : "Received")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption).fixedSize()
                            }
                            .padding(.vertical, Tokens.Space.s2)
                            .padding(.horizontal, Tokens.Space.s2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .ternHover()
                        .help("\(message.subject.isEmpty ? "No subject" : message.subject)\n\(message.sender)\n\(message.date.formatted(date: .complete, time: .shortened))")
                        if message.id != messages.prefix(10).last?.id {
                            Divider().padding(.leading, Tokens.Analytics.symbolSize + Tokens.Space.s3 + Tokens.Space.s2)
                        }
                    }
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
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
                VStack(spacing: 0) {
                    ForEach(receipts.prefix(10)) { receipt in
                        AnalyticsReceiptRow(receipt: receipt, recipients: recipients(for: receipt), mailbox: mailbox)
                        if receipt.id != receipts.prefix(10).last?.id { Divider() }
                    }
                }
                Text("Times show when the receipt arrived, not when the email was opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    private func recipients(for receipt: ReadReceiptStatus) -> [ReadReceiptRecipientStatus] {
        guard let contactAddress else { return receipt.recipients }
        return receipt.recipients.filter { $0.address.lowercased() == contactAddress.lowercased() }
    }
}

private struct AnalyticsListHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer(minLength: Tokens.Space.s2)
            if count > 0 { Text("\(count) shown").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct AnalyticsReceiptRow: View {
    let receipt: ReadReceiptStatus
    let recipients: [ReadReceiptRecipientStatus]
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                if let threadID = receipt.threadID {
                    AnalyticsConversationButton(link: .init(accountID: receipt.accountID,
                        threadID: threadID, messageID: receipt.messageID), mailbox: mailbox) {
                        Text(receipt.subject.isEmpty ? "No subject" : receipt.subject).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.borderless).lineLimit(2)
                    .help("Open email · \(receipt.subject)")
                } else {
                    Text(receipt.subject.isEmpty ? "No subject" : receipt.subject).lineLimit(2)
                        .help(receipt.subject)
                }
                Spacer(minLength: Tokens.Space.s2)
                Text(receipt.sentAt, format: .dateTime.month(.abbreviated).day().year())
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                    .help("Sent \(receipt.sentAt.formatted(date: .complete, time: .shortened))")
            }
            .font(.callout.weight(.medium))
            if recipients.count > 1 {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        ForEach(recipients) { ReadReceiptRecipientRow(recipient: $0) }
                    }
                    .padding(.top, Tokens.Space.s2)
                } label: {
                    Label(ReadReceiptDetails.summary(for: recipients), systemImage: "envelope")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(recipients) { ReadReceiptRecipientRow(recipient: $0) }
            }
        }
        .padding(.vertical, Tokens.Space.s2)
    }
}
