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

    var body: some View {
        Group {
            if let link, let mailbox = app.mailbox, mailbox.account(id: link.accountID) != nil {
                let key = ThreadKey(accountID: link.accountID, threadID: link.threadID)
                ThreadView(key: key, mailbox: mailbox, selectedMessageID: link.messageID)
                    .id(key)
                    .onAppear { app.conversationBecameVisible(key) }
                    .onDisappear { app.conversationStoppedBeingVisible(key) }
                    .toolbar {
                        ToolbarItemGroup {
                            Button("Archive", systemImage: "archivebox") {
                                Task { await mailbox.performNativeAction(.archive, link: link, undoManager: undoManager) }
                            }
                            Button("Move to Trash", systemImage: "trash") {
                                Task { await mailbox.performNativeAction(.trash, link: link, undoManager: undoManager) }
                            }
                            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                                Task {
                                    let quote = selectedQuote.flatMap { $0.belongsTo(accountID: key.accountID, threadID: key.threadID,
                                        messageID: link.messageID) ? $0 : nil }
                                    guard let messageID = await mailbox.nativeReplyMessageID(for: link, preferredMessageID: quote?.messageID),
                                        let id = await mailbox.requestReply(.reply, messageID: messageID,
                                        accountID: key.accountID, selectedText: quote?.text) else { return }
                                    openWindow(id: ComposeWindow.sceneID, value: id)
                                }
                            }
                        }
                    }
            } else {
                ContentUnavailableView("Conversation unavailable", systemImage: "envelope",
                    description: Text("Sign in to its account, then open the conversation again."))
            }
        }
        .frame(minWidth: Tokens.Layout.composeMinWidth, minHeight: Tokens.Layout.composeMinHeight)
        .focusedSceneValue(\.isMainWindow, false)
        .focusedSceneValue(\.conversationLink, link)
    }
}
