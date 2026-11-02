import MailStore
import MessageContent
import SwiftUI

struct AnalyticsCorrespondentsView: View {
    let correspondents: [MailAnalyticsCorrespondent]
    let selectedAccountID: String?
    @Environment(\.openWindow) private var openWindow

    private var maximumCount: Int { max(1, correspondents.map(\.totalCount).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            AnalyticsListHeading(title: "Frequent contacts", subtitle: "Most email in this period", symbol: "person.2", count: min(correspondents.count, 10))
            if correspondents.isEmpty {
                AnalyticsListEmptyState(symbol: "person.2", title: "No contacts in this period",
                    detail: "Choose another date range or load more history.")
            } else {
                VStack(spacing: Tokens.Space.s1) {
                    ForEach(correspondents.prefix(10)) { contact in
                        Button {
                            openWindow(id: MailAnalyticsWindow.sceneID,
                                value: MailAnalyticsRoute(accountID: selectedAccountID, address: contact.address, name: contact.name))
                        } label: {
                            contactRow(contact)
                        }
                        .buttonStyle(.plain)
                        .ternHover()
                        .help("View analytics for \(contact.address)\nLast email \(contact.lastContactAt.formatted(date: .complete, time: .shortened))")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(contact.name.map { $0 + ", " } ?? "")\(contact.address), \(contact.totalCount.formatted()) emails, \(contact.receivedCount.formatted()) received, \(contact.sentCount.formatted()) sent. View analytics.")
                    }
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    private func contactRow(_ contact: MailAnalyticsCorrespondent) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Text(ContactAvatar.initials(name: contact.name ?? "", address: contact.address))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: Tokens.Analytics.symbolSize, height: Tokens.Analytics.symbolSize)
                .background(Color.primary.opacity(Tokens.Opacity.wash), in: Circle())
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(contact.name ?? contact.address).font(.callout.weight(.medium))
                            .foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                        if contact.name != nil {
                            Text(contact.address).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                        Text(contact.totalCount, format: .number).font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: Tokens.Space.s2) {
                            directionCount(contact.receivedCount, symbol: "arrow.down.left", color: Tokens.Analytics.received)
                            directionCount(contact.sentCount, symbol: "arrow.up.right", color: Tokens.Analytics.sent)
                        }
                    }
                    .monospacedDigit().fixedSize()
                }
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(Tokens.Opacity.wash))
                    HStack(spacing: 0) {
                        Rectangle().fill(Tokens.Analytics.received)
                            .frame(width: geometry.size.width * CGFloat(contact.receivedCount) / CGFloat(maximumCount))
                        Rectangle().fill(Tokens.Analytics.sent)
                            .frame(width: geometry.size.width * CGFloat(contact.sentCount) / CGFloat(maximumCount))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: Tokens.Space.s1)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Tokens.Space.s3)
        .padding(.horizontal, Tokens.Space.s2)
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    private func directionCount(_ value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: Tokens.Space.s0_5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(value, format: .number).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

struct AnalyticsRecentMessagesView: View {
    let messages: [MailAnalyticsMessage]
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            AnalyticsListHeading(title: "Recent emails", subtitle: "Latest in this period", symbol: "tray", count: min(messages.count, 10))
            if messages.isEmpty {
                AnalyticsListEmptyState(symbol: "tray", title: "No email in this period",
                    detail: "Choose another date range to see your messages.")
            } else {
                VStack(spacing: 0) {
                    ForEach(messages.prefix(10)) { message in
                        AnalyticsConversationButton(link: .init(accountID: message.accountID,
                            threadID: message.threadID, messageID: message.messageID), mailbox: mailbox) {
                            messageRow(message)
                        }
                        .buttonStyle(.plain)
                        .ternHover()
                        .help("\(message.subject.isEmpty ? "No subject" : message.subject)\n\(message.sender)\n\(message.date.formatted(date: .complete, time: .shortened))")
                        if message.id != messages.prefix(10).last?.id {
                            Divider().opacity(Tokens.Opacity.outline)
                                .padding(.leading, Tokens.Analytics.symbolSize + Tokens.Space.s3 + Tokens.Space.s2)
                        }
                    }
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    private func messageRow(_ message: MailAnalyticsMessage) -> some View {
        let sent = message.direction == .sent
        let color = sent ? Tokens.Analytics.sent : Tokens.Analytics.received
        let sender = EmailAddress.parseList(message.sender).first
        let name = sender?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = name.isEmpty ? (sender?.address ?? message.sender) : name
        let dateFormat: Date.FormatStyle = Calendar.current.isDate(message.date, equalTo: .now, toGranularity: .year)
            ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year()
        return HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: sent ? "arrow.up.right" : "arrow.down.left")
                .font(.callout.weight(.medium)).foregroundStyle(color)
                .frame(width: Tokens.Analytics.symbolSize, height: Tokens.Analytics.symbolSize)
                .background(color.opacity(Tokens.Opacity.wash), in: Circle())
                .accessibilityLabel(sent ? "Sent" : "Received")
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                    Text(displayName).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(message.sender).accessibilityLabel(message.sender)
                    Spacer(minLength: 0)
                    Text(message.date, format: dateFormat)
                        .font(.caption).foregroundStyle(.secondary).fixedSize()
                        .accessibilityLabel(message.date.formatted(date: .complete, time: .shortened))
                }
                Text(message.subject.isEmpty ? "No subject" : message.subject)
                    .font(.callout.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, Tokens.Space.s3)
        .padding(.horizontal, Tokens.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct AnalyticsReceiptsView: View {
    let receipts: [ReadReceiptStatus]
    let error: String?
    let contactAddress: String?
    let mailbox: MailboxModel
    @State private var showsExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            AnalyticsListHeading(title: "Read receipts", subtitle: "Across all history", symbol: "envelope.badge", count: min(receipts.count, 10))
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Tokens.Status.error)
            } else if receipts.isEmpty {
                AnalyticsListEmptyState(symbol: "envelope.badge", title: "No receipt requests yet",
                    detail: "Request a receipt from the send options when composing.")
            } else {
                VStack(spacing: 0) {
                    ForEach(receipts.prefix(10)) { receipt in
                        AnalyticsReceiptRow(receipt: receipt, recipients: recipients(for: receipt), mailbox: mailbox)
                        if receipt.id != receipts.prefix(10).last?.id { Divider().opacity(Tokens.Opacity.outline) }
                    }
                }
                Text("No receipt means the reading status is unknown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $showsExplanation) {
                Text("Receipts depend on the recipient's email app and settings. Times show when a receipt arrived, not when the email was opened. Request receipts from the send options when composing.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Tokens.Space.s2)
            } label: {
                Text("About read receipts").font(.caption).foregroundStyle(.secondary)
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
    let subtitle: String
    let symbol: String
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: symbol)
                .font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Space.s10, height: Tokens.Space.s10)
                .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count) shown").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .padding(.horizontal, Tokens.Space.s2).padding(.vertical, Tokens.Space.s1)
                    .background(Color.primary.opacity(Tokens.Opacity.wash), in: Capsule())
                    .fixedSize()
            }
        }
    }
}

private struct AnalyticsListEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tertiary)
                .frame(width: Tokens.Analytics.symbolSize)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnalyticsReceiptRow: View {
    let receipt: ReadReceiptStatus
    let recipients: [ReadReceiptRecipientStatus]
    let mailbox: MailboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
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
                Text("Sent \(receipt.sentAt.formatted(date: .abbreviated, time: .omitted))")
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
        .padding(.vertical, Tokens.Space.s3)
    }
}
