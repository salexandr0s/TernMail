import MailStore
import MessageContent
import SwiftUI

/// Disclosure, identity and message actions have separate hit targets.
struct MessageHeader<SenderItems: View>: View {
    let message: MessageDetail
    let mailbox: MailboxModel
    let isExpanded: Bool
    var selectedText = ""
    var blockedTrackers = 0
    var showsSize = false
    let compose: (MailboxModel.ComposeStart) -> Void
    let onMarkUnreadFromHere: () -> Void
    let onToggle: () -> Void
    @ViewBuilder let senderItems: SenderItems
    @State private var showsDetails = false
    @State private var showsSender = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .ternHover()
            .help(isExpanded ? "Collapse message" : "Expand message")
            .accessibilityLabel(isExpanded ? "Collapse message" : "Expand message")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("message-disclosure-\(message.id)")
            .messageHeaderControl()

            Button { showsSender = true } label: {
                ContactAvatar(accountID: message.record.accountID, address: message.senderAddress,
                              name: message.senderDisplayName, cache: mailbox.cache, accounts: mailbox.accountStore)
            }
            .buttonStyle(.plain)
            .help("Show sender details")
            .accessibilityLabel("Show details for \(message.senderDisplayName)")
            .accessibilityIdentifier("sender-profile-\(message.id)")
            .messageHeaderControl()
            .popover(isPresented: $showsSender, arrowEdge: .bottom) {
                SenderProfilePopover(accountID: message.record.accountID, address: message.senderAddress,
                                     name: message.senderDisplayName, mailbox: mailbox)
            }

            ViewThatFits(in: .horizontal) {
                lines(isNarrow: false)
                lines(isNarrow: true)
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .overlayPreferenceValue(MessageHeaderControlBounds.self) { bounds in
            GeometryReader { geometry in
                MessageHeaderClickSurface(messageID: message.id, isExpanded: isExpanded,
                    controlRects: bounds.map { geometry[$0] }, onToggle: onToggle)
            }
        }
        .ternHover(radius: Tokens.Radius.md)
        .menuIndicator(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("message-header-\(message.id)")
        .contextMenu {
            MessageMenuItems(message: message, mailbox: mailbox, selectedText: selectedText,
                             markUnreadFromHere: onMarkUnreadFromHere, compose: compose)
            senderItems
        }
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            MessageDetailsView(message: message, mailbox: mailbox, blockedTrackers: blockedTrackers, showsSize: showsSize)
        }
        .onChange(of: isExpanded) { _, expanded in if !expanded { showsDetails = false } }
    }

    private func lines(isNarrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            HStack(spacing: Tokens.Space.s2) {
                HStack(spacing: Tokens.Space.s1) {
                    if message.isUnread {
                        Circle().fill(Color.accentColor).frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                            .accessibilityLabel("Unread")
                            .allowsHitTesting(false)
                    }
                    MessageAddressMenu(address: .init(name: message.senderDisplayName, address: message.senderAddress),
                                       accountID: message.record.accountID, mailbox: mailbox)
                        .font(.body.weight(message.isUnread ? .semibold : .medium))
                        .accessibilityIdentifier("message-sender-\(message.id)")
                        .messageHeaderControl()
                }
                .frame(minWidth: isNarrow ? 0 : Tokens.Layout.senderMinWidth, maxWidth: .infinity, alignment: .leading)

                Text(ThreadDate.short(message.record.date))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize()
                    .help(message.record.date.formatted(date: .complete, time: .shortened))
                    .allowsHitTesting(false)
                MessageActions(message: message, mailbox: mailbox, selectedText: selectedText, compose: compose,
                               showsReply: isExpanded && !isNarrow, showsStar: !isNarrow || message.isStarred,
                               markUnreadFromHere: onMarkUnreadFromHere) { senderItems }
                    .messageHeaderControl()
            }

            if isExpanded {
                HStack(spacing: Tokens.Space.s2) {
                    Text(recipientSummary).lineLimit(1).truncationMode(.middle)
                        .allowsHitTesting(false)
                    Button("Show details") { showsDetails = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Show sender, recipients and message details")
                        .accessibilityIdentifier("message-details-\(message.id)")
                        .fixedSize()
                        .messageHeaderControl()
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary)
                if message.labels.contains(SystemLabel.sent), let messageID = message.record.rfcMessageID {
                    ReadReceiptBadge(accountID: message.record.accountID, rfcMessageID: messageID, cache: mailbox.cache)
                        .messageHeaderControl()
                }
            } else {
                Text(MessagePreview.text(for: message))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).allowsHitTesting(false)
            }
        }
    }

    private var recipientSummary: String {
        let recipients = EmailAddress.parseList(message.record.recipients)
        let own = mailbox.account(id: message.record.accountID)?.account.email.lowercased()
        let names = recipients.prefix(2).map { address in
            address.normalized == own ? "me" : (address.name ?? address.address)
        }
        let extra = max(0, recipients.count - names.count) + EmailAddress.parseList(message.record.cc ?? "").count + EmailAddress.parseList(message.record.bcc ?? "").count
        let base = names.isEmpty ? "Recipients" : "To: " + names.joined(separator: ", ")
        return extra > 0 ? base + " · +\(extra)" : base
    }
}

struct MessageDetailsView: View {
    let message: MessageDetail
    let mailbox: MailboxModel
    let blockedTrackers: Int
    let showsSize: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Text("Message details").font(.headline)
                addresses("From", message.record.sender)
                addresses("To", message.record.recipients)
                if let cc = message.record.cc, !cc.isEmpty { addresses("Cc", cc) }
                if let bcc = message.record.bcc, !bcc.isEmpty { addresses("Bcc", bcc) }
                if let replyTo = message.record.replyTo, !replyTo.isEmpty { addresses("Reply to", replyTo) }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    caption("Date")
                    Text(message.record.date.formatted(date: .complete, time: .shortened))
                        .textSelection(.enabled)
                }
                if showsSize {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        caption("Message size")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(message.record.sizeEstimate), countStyle: .file))
                    }
                }
                if blockedTrackers > 0 {
                    Divider()
                    Label("^[\(blockedTrackers) tracking image](inflect: true) blocked", systemImage: "hand.raised")
                        .font(.callout)
                    Text("Tracking images stay blocked when you load other images.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s4)
        }
        .frame(width: Tokens.Popover.width)
        .frame(maxHeight: Tokens.Popover.maxListHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }

    private func addresses(_ title: String, _ raw: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            caption(title)
            let addresses = EmailAddress.parseList(raw)
            if addresses.isEmpty {
                Text(raw.isEmpty ? "Not specified" : raw).textSelection(.enabled)
            } else {
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                    MessageAddressMenu(address: address, accountID: message.record.accountID,
                                       mailbox: mailbox, showsFullAddress: true)
                }
            }
        }
    }
}

extension MessageDetail {
    var senderAddress: String { parsedSenderAddress ?? record.sender }
    var parsedSenderAddress: String? { EmailAddress.parseList(record.sender).first?.address }
    var senderDisplayName: String {
        let address = EmailAddress.parseList(record.sender).first
        return address?.name ?? address?.address ?? record.sender
    }
}

/// Preview cleanup is local and bounded. It never fetches or parses collapsed HTML.
enum MessagePreview {
    static func text(for message: MessageDetail) -> String {
        let preview = cleaned(message.record.snippet)
        if !preview.isEmpty { return preview }
        if let plain = message.body?.plainText {
            let local = cleaned(String(plain.prefix(2048)))
            if !local.isEmpty { return local }
        }
        return message.attachments.isEmpty ? "No preview available" : "Message with attachments"
    }

    static func cleaned(_ raw: String) -> String {
        var text = String(raw.prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
        for phrase in ["If you do not see this email correctly, follow this link.",
                       "If you cannot view this email, click here.", "View this email in your browser."] {
            if let range = text.range(of: phrase, options: [.anchored, .caseInsensitive]) {
                text.removeSubrange(range)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
