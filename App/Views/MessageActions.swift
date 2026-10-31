import AppKit
import MailStore
import MessageContent
import SwiftUI

/// The row of controls in an expanded message's header.
struct MessageActions: View {
    let message: MessageDetail
    let mailbox: MailboxModel
    let selectedText: String
    let compose: (MailboxModel.ComposeStart) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            if message.labels.contains(SystemLabel.draft) {
                Button("Edit Draft", systemImage: "pencil") {
                    compose(.editDraft(messageID: message.id, accountID: message.record.accountID))
                }.help("Edit Draft")
            } else {
                Button { mailbox.toggleMessageStar(message) } label: {
                    Label(message.isStarred ? "Remove Star" : "Star", systemImage: message.isStarred ? "star.fill" : "star")
                        .foregroundStyle(message.isStarred ? AnyShapeStyle(Tokens.Status.star) : AnyShapeStyle(.secondary))
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                }.help(message.isStarred ? "Remove Star" : "Star")
                let primary = MessageMenuItems.primaryReply(to: message, in: mailbox)
                Button(primary == .replyAll ? "Reply All" : "Reply", systemImage: primary == .replyAll ? "arrowshape.turn.up.left.2" : "arrowshape.turn.up.left") {
                    MessageMenuItems.reply(primary, to: message, in: mailbox, selectedText: selectedText, openWindow: openWindow)
                }.help(primary == .replyAll ? "Reply All" : "Reply")
                Menu {
                    MessageMenuItems(message: message, mailbox: mailbox, selectedText: selectedText)
                } label: { Label("More", systemImage: "ellipsis.circle").frame(width: Tokens.Space.s6, height: Tokens.Space.s6) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("More actions for this message")
            }
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).imageScale(.medium).foregroundStyle(.secondary)
    }
}

/// One message's commands, shared by the More button and the card's context
/// menu. The context menu passes `markUnreadFromHere` and shows the star.
struct MessageMenuItems: View {
    let message: MessageDetail
    let mailbox: MailboxModel
    let selectedText: String
    var markUnreadFromHere: (() -> Void)? = nil
    var showsStar = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
        if markUnreadFromHere != nil || showsStar {
            Divider()
            if let markUnreadFromHere { Button("Mark Unread from Here") { markUnreadFromHere() } }
            if showsStar { Button(message.isStarred ? "Remove Star" : "Star") { mailbox.toggleMessageStar(message) } }
        }
        Divider()
        Button("Show Original") { openWindow(id: OriginalMessageWindow.sceneID, value: link) }
        Button("Print Message…") { printMessage() }.disabled(message.body == nil)
        Button("Export Message as PDF…") { printMessage(pdf: true) }.disabled(message.body == nil)
        if let url = link.ternURL { Button("Copy Link") { copy(url) } }
        if let email = mailbox.account(id: message.record.accountID)?.account.email, let url = link.gmailURL(email: email) {
            Button("Copy Gmail Link") { copy(url) }
            Button("Open in Gmail") { NSWorkspace.shared.open(url) }
        }
        let file = MessageFileItem(message, mailbox: mailbox)
        ShareLink(item: file, preview: file.preview) { Text("Share") }
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button("Copy Address") { NSPasteboard.general.replaceContents(with: address.address) }
            Button("New Message") {
                Task {
                    guard let id = await mailbox.startMessage(to: address, accountID: accountID) else { return }
                    openWindow(id: ComposeWindow.sceneID, value: id)
                }
            }
            Button("Search Messages From") { mailbox.searchFromAddress(address.address, accountID: accountID) }
            Button("Search Messages To") { mailbox.searchToAddress(address.address, accountID: accountID) }
            Button("Create Filter…") { mailbox.requestFilter(sender: address.address, recipients: nil, subject: nil, accountID: accountID) }
        } label: { Text(address.name ?? address.address).lineLimit(1) }
        .menuStyle(.borderlessButton)
        .help(address.displayString)
        .accessibilityLabel("Address actions for \(address.displayString)")
    }
}
