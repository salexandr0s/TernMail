import MailStore
import MessageContent
import SwiftUI

struct ConversationWindow: View {
    static let sceneID = "conversation"
    let link: MailLink?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager
    @FocusedValue(\.selectedMailQuote) private var selectedQuote
    @State private var subject = ""
    @State private var participants = ""
    @State private var isWindowVisible = false

    private struct ReaderIdentity: Hashable {
        let key: ThreadKey
        let messageID: String?
        let owner: ObjectIdentifier
        let lifecycle: Int
    }

    var body: some View {
        Group {
            if let link, let mailbox = app.mailbox, let owner = mailbox.account(id: link.accountID) {
                let key = ThreadKey(accountID: link.accountID, threadID: link.threadID)
                ThreadView(key: key, mailbox: mailbox, selectedMessageID: link.messageID, isReaderActive: isWindowVisible) { detail in
                    subject = detail.thread.subject
                    participants = detail.thread.participants
                }
                    .id(ReaderIdentity(key: key, messageID: link.messageID, owner: ObjectIdentifier(owner),
                                       lifecycle: ReaderCacheLifecycle.shared.revision))
                    .onAppear { app.conversationBecameVisible(key) }
                    .onDisappear { app.conversationStoppedBeingVisible(key) }
                    .toolbar {
                        ToolbarItemGroup {
                            Button("Archive", systemImage: "archivebox") {
                                Task { await mailbox.performNativeAction(.archive, link: link, undoManager: undoManager) }
                            }
                            .help("Archive")
                            Button("Move to Trash", systemImage: "trash") {
                                Task { await mailbox.performNativeAction(.trash, link: link, undoManager: undoManager) }
                            }
                            .help("Move to Trash")
                        }
                        ToolbarItemGroup {
                            Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(.reply, in: mailbox, link: link, key: key) }
                                .help("Reply")
                            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { reply(.replyAll, in: mailbox, link: link, key: key) }
                                .help("Reply All")
                            Button("Forward", systemImage: "arrowshape.turn.up.right") { reply(.forward, in: mailbox, link: link, key: key) }
                                .help("Forward")
                        }
                    }
            } else {
                ContentUnavailableView("Conversation Unavailable", systemImage: "envelope",
                    description: Text("Sign in to its account, then open the conversation again."))
            }
        }
        .background(ReaderWindowVisibility { isWindowVisible = $0 })
        .navigationTitle(subject.isEmpty ? "Conversation" : subject)
        .navigationSubtitle(participants)
        .frame(minWidth: Tokens.Layout.conversationMinWidth, minHeight: Tokens.Layout.conversationMinHeight)
        .focusedSceneValue(\.isMainWindow, false)
        .focusedSceneValue(\.conversationLink, link)
    }

    /// Answers the newest message, quoting any selected text.
    private func reply(_ kind: ReplyKind, in mailbox: MailboxModel, link: MailLink, key: ThreadKey) {
        Task {
            let quote = selectedQuote.flatMap { $0.belongsTo(accountID: key.accountID, threadID: key.threadID,
                messageID: link.messageID) ? $0 : nil }
            guard let messageID = await mailbox.nativeReplyMessageID(for: link, preferredMessageID: quote?.messageID),
                let id = await mailbox.requestReply(kind, messageID: messageID,
                accountID: key.accountID, selectedText: quote?.text) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }
}
