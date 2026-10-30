import AppKit
import MailStore
import MessageContent
import SwiftUI

struct MessageActions: View {
    let message: MessageDetail
    let mailbox: MailboxModel
    let selectedText: String
    let compose: (MailboxModel.ComposeStart) -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var original: OriginalMessage?
    @State private var isLoadingOriginal = false

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            if message.labels.contains(SystemLabel.draft) {
                Button("Edit Draft", systemImage: "pencil") {
                    compose(.editDraft(messageID: message.id, accountID: message.record.accountID))
                }.help("Edit Draft")
            } else {
                Button { mailbox.toggleMessageStar(message) } label: {
                    Label(message.isStarred ? "Remove Star" : "Star", systemImage: message.isStarred ? "star.fill" : "star")
                        .foregroundStyle(message.isStarred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                }.help(message.isStarred ? "Remove Star" : "Star")
                Button(primaryReply == .replyAll ? "Reply All" : "Reply", systemImage: primaryReply == .replyAll ? "arrowshape.turn.up.left.2" : "arrowshape.turn.up.left") {
                    reply(primaryReply)
                }.help(primaryReply == .replyAll ? "Reply All" : "Reply")
                Menu {
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
                    Divider()
                    Button("Show Original") { showOriginal() }.disabled(isLoadingOriginal)
                    Button("Print Message…") { printMessage() }.disabled(message.body == nil)
                    Button("Export Message as PDF…") { printMessage(pdf: true) }.disabled(message.body == nil)
                    if let url = link.ternURL { Button("Copy Link") { copy(url) } }
                    if let email = mailbox.account(id: message.record.accountID)?.account.email, let url = link.gmailURL(email: email) {
                        Button("Copy Gmail Link") { copy(url) }
                        Button("Open in Gmail") { NSWorkspace.shared.open(url) }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle").frame(width: Tokens.Space.s6, height: Tokens.Space.s6) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .accessibilityLabel("More actions for this message")
            }
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).imageScale(.medium).foregroundStyle(.secondary)
        .sheet(item: $original) { OriginalMessageView(message: $0) }
    }

    private var link: MailLink { MailLink(accountID: message.record.accountID, threadID: message.record.threadID, messageID: message.id) }

    private var primaryReply: ReplyKind {
        let own = mailbox.account(id: message.record.accountID)?.account.email.lowercased()
        let sender = EmailAddress.parseList(message.record.sender).first?.normalized
        let others = EmailAddress.parseList([message.record.recipients, message.record.cc ?? ""].joined(separator: ","))
            .map(\.normalized).filter { $0 != own && $0 != sender }
        return others.isEmpty ? .reply : .replyAll
    }

    private func reply(_ kind: ReplyKind) {
        Task {
            guard let id = await mailbox.requestReply(kind, messageID: message.id, accountID: message.record.accountID, selectedText: selectedText) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }

    private func showOriginal() {
        guard let owner = mailbox.account(id: message.record.accountID) else { return }
        isLoadingOriginal = true
        Task {
            defer { isLoadingOriginal = false }
            do {
                let bytes = try await owner.engine.rawMessage(id: message.id)
                guard mailbox.account(id: message.record.accountID) === owner else { return }
                original = OriginalMessage(record: message.record, bytes: bytes)
            } catch { mailbox.notice = .init(message: "The original message could not be loaded.", isError: true) }
        }
    }

    private func printMessage(pdf: Bool = false) {
        ConversationPrintController.show(subject: message.record.subject, messages: [message], exportsPDF: pdf) { error in
            if let error { mailbox.notice = .init(message: error, isError: true) }
        }
    }

    private func copy(_ url: URL) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
}

struct MessageAddressMenu: View {
    let address: EmailAddress
    let accountID: String
    let mailbox: MailboxModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button("Copy Address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address.address, forType: .string) }
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
