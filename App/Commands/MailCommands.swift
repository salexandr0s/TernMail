import SwiftUI

/// Menu bar commands. Shortcuts follow Apple Mail.
struct MailCommands: Commands {
    let app: AppModel
    // Tern has one mailbox window. Its commands remain available when focus
    // moves between a list, WebKit and the menu bar.
    var mailbox: MailboxModel? { app.mailbox }
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { compose(.newMessage) }
                .keyboardShortcut("n")
                .disabled(mailbox == nil)
        }
        CommandMenu("Message") {
            Button("Archive") { mailbox?.perform(.archive) }
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(!(mailbox?.canArchive ?? false))
            Button("Move to Trash") { mailbox?.perform(.trash) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!(mailbox?.canTrash ?? false))
            Divider()
            Button(isRead ? "Mark as Unread" : "Mark as Read") { mailbox?.toggleRead() }
                .keyboardShortcut("u", modifiers: [.shift, .command])
                .disabled(!hasSelection)
            Button(isStarred ? "Remove Star" : "Star") { mailbox?.toggleStar() }
                .keyboardShortcut("l", modifiers: [.shift, .command])
                .disabled(!hasSelection)
        }
        CommandMenu("Mailbox") {
            Button("Check for New Mail") { mailbox?.syncNow() }
                .keyboardShortcut("n", modifiers: [.shift, .command])
                .disabled(mailbox == nil)
            Divider()
            Button("Sign Out…") { app.isConfirmingSignOut = true }
                .disabled(mailbox == nil)
        }
    }

    /// Opens a compose window once its draft exists. A failure shows in the mailbox window.
    private func compose(_ start: MailboxModel.ComposeStart) {
        guard let mailbox else { return }
        Task {
            guard let id = await mailbox.startCompose(start) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }

    private var hasSelection: Bool {
        !(mailbox?.selectedThreadIDs.isEmpty ?? true)
    }

    private var isRead: Bool {
        guard let mailbox else { return false }
        return mailbox.allRead(mailbox.selectedThreadIDs)
    }

    private var isStarred: Bool {
        guard let mailbox else { return false }
        return mailbox.allStarred(mailbox.selectedThreadIDs)
    }
}
