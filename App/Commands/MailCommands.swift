import SwiftUI

extension FocusedValues {
    @Entry var mailbox: MailboxModel?
}

/// Menu bar commands. Shortcuts follow Apple Mail.
struct MailCommands: Commands {
    let app: AppModel
    @FocusedValue(\.mailbox) private var mailbox

    var body: some Commands {
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
