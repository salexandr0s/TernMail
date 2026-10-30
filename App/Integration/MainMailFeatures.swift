import MessageContent
import SwiftUI

/// Keep feature presentation outside the split-view sizing expression.
struct MainMailFeatures: ViewModifier {
    let mailbox: MailboxModel
    let libraryToolbar: AttachmentLibraryToolbarState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .modifier(AttachmentLibraryPresentation(mailbox: mailbox, toolbar: libraryToolbar))
            .background(TriagePresentationHost(mailbox: mailbox))
            .onAppear { MailScriptingBridge.shared.refreshSelection(mailbox) }
            .onChange(of: mailbox.selectedThreadIDs) { _, _ in MailScriptingBridge.shared.refreshSelection(mailbox) }
            .onChange(of: mailbox.selectedMessageRows) { _, _ in MailScriptingBridge.shared.refreshSelection(mailbox) }
            .onChange(of: mailbox.conversationWindowRequest) { _, link in
                guard let link else { return }
                mailbox.conversationWindowRequest = nil
                openWindow(id: ConversationWindow.sceneID, value: link)
            }
    }
}
