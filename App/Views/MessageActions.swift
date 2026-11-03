import AppKit
import MailStore
import MessageContent
import SwiftUI

/// Message controls keep the same targets in open, collapsed and narrow headers.
struct MessageActions<SenderItems: View>: View {
    let message: MessageDetail
    let mailbox: MailboxModel
    let selectedText: String
    let compose: (MailboxModel.ComposeStart) -> Void
    var showsReply = true
    var showsStar = true
    var markUnreadFromHere: (() -> Void)? = nil
    /// The sender's reading choices, after the message commands in More.
    @ViewBuilder let senderItems: SenderItems
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            if message.labels.contains(SystemLabel.draft) {
                if showsReply {
                    Button {
                        compose(.editDraft(messageID: message.id, accountID: message.record.accountID))
                    } label: {
                        MessageActionIcon("Edit Draft", systemImage: "pencil")
                    }
                    .help("Edit Draft")
                    .accessibilityIdentifier("message-edit-draft-\(message.id)")
                    .ternHover()
                }
            } else {
                if showsStar {
                    Button { mailbox.toggleMessageStar(message) } label: {
                        MessageActionIcon(message.isStarred ? "Remove Star" : "Star",
                                          systemImage: message.isStarred ? "star.fill" : "star")
                            .foregroundStyle(message.isStarred ? AnyShapeStyle(Tokens.Status.star) : AnyShapeStyle(.secondary))
                    }
                    .help(message.isStarred ? "Remove Star" : "Star")
                    .accessibilityIdentifier("message-star-\(message.id)")
                    .ternHover()
                }
                if showsReply {
                    let primary = MessageMenuItems.primaryReply(to: message, in: mailbox)
                    Button {
                        MessageMenuItems.reply(primary, to: message, in: mailbox, selectedText: selectedText, openWindow: openWindow)
                    } label: {
                        MessageActionIcon(primary == .replyAll ? "Reply All" : "Reply",
                                          systemImage: primary == .replyAll ? "arrowshape.turn.up.left.2" : "arrowshape.turn.up.left")
                    }
                    .help(primary == .replyAll ? "Reply All" : "Reply")
                    .accessibilityIdentifier("message-reply-\(message.id)")
                    .ternHover()
                }
            }
            Menu {
                MessageMenuItems(message: message, mailbox: mailbox, selectedText: selectedText,
                                 markUnreadFromHere: markUnreadFromHere, compose: compose)
                senderItems
            } label: { MessageActionIcon("More actions for this message", systemImage: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for this message")
            .accessibilityIdentifier("message-more-\(message.id)")
            .help("More actions for this message")
            .ternHover()
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).imageScale(.medium)
        .foregroundStyle(.secondary)
    }
}

/// Shared label dimensions retain the native button's keyboard focus treatment.
private struct MessageActionIcon: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            .contentShape(Rectangle())
    }
}

/// One message's commands, shared by More and the header's context menu.
struct MessageMenuItems: View {
    let message: MessageDetail
    let mailbox: MailboxModel
    let selectedText: String
    var markUnreadFromHere: (() -> Void)? = nil
    var showsStar = true
    var compose: ((MailboxModel.ComposeStart) -> Void)? = nil
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if message.labels.contains(SystemLabel.draft) {
            Button("Edit Draft", systemImage: "pencil") { editDraft() }
        } else {
            replyItems
            Divider()
            Button(message.isUnread ? "Mark as Read" : "Mark as Unread",
                   systemImage: message.isUnread ? "envelope.open" : "envelope.badge") {
                mailbox.performReadingAction(message.isUnread ? .markRead : .markUnread,
                                             name: message.isUnread ? "Mark as Read" : "Mark as Unread",
                                             messageID: message.id, accountID: message.record.accountID)
            }
            if let markUnreadFromHere { Button("Mark Unread from Here") { markUnreadFromHere() } }
            if showsStar {
                Button(message.isStarred ? "Remove Star" : "Star", systemImage: message.isStarred ? "star.slash" : "star") {
                    mailbox.toggleMessageStar(message)
                }
            }
        }
        Divider()
        linkItems
        Divider()
        Button("Print Message…", systemImage: "printer") { printMessage() }.disabled(message.body == nil)
        Button("Export Message as PDF…") { printMessage(pdf: true) }.disabled(message.body == nil)
        Button("Show Original") { openWindow(id: OriginalMessageWindow.sceneID, value: link) }
    }

    @ViewBuilder private var replyItems: some View {
        Button("Reply") { reply(.reply) }
        Button("Reply All") { reply(.replyAll) }
        Button("Forward") { reply(.forward) }
        Button("Forward as Attachment") {
            Task {
                guard let id = await mailbox.startForwardingAttachment(messageID: message.id, accountID: message.record.accountID) else { return }
                openWindow(id: ComposeWindow.sceneID, value: id)
            }
        }
        if message.labels.contains(SystemLabel.sent) {
            Button("Send Again") {
                guard let owner = mailbox.account(id: message.record.accountID) else { return }
                Task {
                    guard let id = await mailbox.startSendAgain(messageID: message.id, accountID: message.record.accountID),
                          mailbox.account(id: message.record.accountID) === owner else { return }
                    openWindow(id: ComposeWindow.sceneID, value: id)
                }
            }
        }
    }

    @ViewBuilder private var linkItems: some View {
        if let url = link.ternURL { Button("Copy Link") { copy(url) } }
        if let email = mailbox.account(id: message.record.accountID)?.account.email, let url = link.gmailURL(email: email) {
            Button("Copy Gmail Link") { copy(url) }
            Button("Open in Gmail") { NSWorkspace.shared.open(url) }
        }
        let file = MessageFileItem(message, mailbox: mailbox)
        ShareLink(item: file, preview: file.preview) { Text("Share Message…") }
    }

    private var link: MailLink { MailLink(accountID: message.record.accountID, threadID: message.record.threadID, messageID: message.id) }

    /// Reply All when anyone besides the sender and the reader was on the message.
    static func primaryReply(to message: MessageDetail, in mailbox: MailboxModel) -> ReplyKind {
        let own = mailbox.account(id: message.record.accountID)?.account.email.lowercased()
        let sender = EmailAddress.parseList(message.record.sender).first?.normalized
        let others = EmailAddress.parseList([message.record.recipients, message.record.cc ?? ""].joined(separator: ","))
            .map(\.normalized).filter { $0 != own && $0 != sender }
        return others.isEmpty ? .reply : .replyAll
    }

    static func reply(_ kind: ReplyKind, to message: MessageDetail, in mailbox: MailboxModel, selectedText: String,
                      openWindow: OpenWindowAction) {
        Task {
            guard let id = await mailbox.requestReply(kind, messageID: message.id, accountID: message.record.accountID, selectedText: selectedText) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }

    private func reply(_ kind: ReplyKind) {
        Self.reply(kind, to: message, in: mailbox, selectedText: selectedText, openWindow: openWindow)
    }

    private func editDraft() {
        let start = MailboxModel.ComposeStart.editDraft(messageID: message.id, accountID: message.record.accountID)
        if let compose { compose(start) }
        else {
            Task {
                guard let id = await mailbox.startCompose(start) else { return }
                openWindow(id: ComposeWindow.sceneID, value: id)
            }
        }
    }

    private func printMessage(pdf: Bool = false) {
        ConversationPrintController.show(subject: message.record.subject, messages: [message], exportsPDF: pdf) { error in
            if let error { mailbox.notice = .init(message: error, isError: true) }
        }
    }

    private func copy(_ url: URL) { NSPasteboard.general.replaceContents(with: url.absoluteString) }
}

struct MessageAddressMenu: View {
    let address: EmailAddress
    let accountID: String
    let mailbox: MailboxModel
    var displayName: String? = nil
    var showsFullAddress = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if showsFullAddress {
            HStack(alignment: .top, spacing: Tokens.Space.s1) {
                Text(address.displayString)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                addressMenu.fixedSize()
            }
        } else {
            addressMenu
        }
    }

    private var addressMenu: some View {
        Menu {
            Text(address.address)
            Divider()
            Button("Copy Address") { NSPasteboard.general.replaceContents(with: address.address) }
            Button("New Message") {
                Task {
                    guard let id = await mailbox.startMessage(to: address, accountID: accountID) else { return }
                    openWindow(id: ComposeWindow.sceneID, value: id)
                }
            }
            Divider()
            Button("Search Messages From") { mailbox.searchFromAddress(address.address, accountID: accountID) }
            Button("Search Messages To") { mailbox.searchToAddress(address.address, accountID: accountID) }
            Button("Create Filter…") { mailbox.requestFilter(sender: address.address, recipients: nil, subject: nil, accountID: accountID) }
        } label: {
            if showsFullAddress {
                Label("Address actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .contentShape(Rectangle())
            } else {
                Text(displayName ?? address.name ?? address.address)
                    .lineLimit(1)
                    .frame(minHeight: Tokens.Space.s6, alignment: .leading)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(showsFullAddress ? .hidden : .visible)
        .ternHover()
        .help(address.displayString)
        .accessibilityLabel("Address actions for \(address.displayString)")
    }
}
