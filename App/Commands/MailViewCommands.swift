import AppKit
import MailStore
import MessageContent
import SwiftUI

extension FocusedValues {
    @Entry var conversationLink: MailLink?
}

struct MailViewCommands: Commands {
    @FocusedValue(\.mailboxModel) private var mailbox
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MailWindowPreferences.hidesReaderKey) private var hidesReader = false
    @AppStorage("showMessageSize") private var showsMessageSize = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Show Viewing Pane", isOn: Binding(get: { !hidesReader }, set: { hidesReader = !$0 }))
            MessageListViewOptions()
            Toggle("Message Size", isOn: $showsMessageSize)
            Divider()
            Button("Customize Toolbar…") { NSApp.keyWindow?.runToolbarCustomizationPalette(nil) }
        }
        CommandGroup(after: .windowArrangement) {
            Button("Open Conversation in New Window") {
                guard let key = mailbox?.selectedThreadIDs.first else { return }
                let messageID = mailbox?.listPreferences.conversations == false ? mailbox?.selectedMessageRows.first?.messageID : nil
                openWindow(id: ConversationWindow.sceneID, value: MailLink(accountID: key.accountID, threadID: key.threadID, messageID: messageID))
            }
            .disabled(mailbox?.selectedThreadIDs.count != 1)
        }
    }
}
