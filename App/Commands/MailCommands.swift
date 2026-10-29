import MessageContent
import SwiftUI

/// Menu bar commands. Shortcuts follow Apple Mail.
struct MailCommands: Commands {
    let app: AppModel
    // Tern has one mailbox window. Its commands remain available when focus
    // moves between a list, WebKit and the menu bar.
    var mailbox: MailboxModel? { app.mailbox }
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.composeModel) private var compose

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { open(.newMessage) }
                .keyboardShortcut("n")
                .disabled(mailbox == nil)
            Button("Attach Files…") { compose?.isChoosingFiles = true }
                .keyboardShortcut("a", modifiers: [.shift, .command])
                .disabled(!canEdit)
        }
        CommandGroup(after: .undoRedo) {
            Button("Undo Send") { undoSend() }
                .disabled(mailbox?.undoableSendID == nil)
        }
        CommandMenu("Message") {
            Button("Send") { Task { await compose?.send() } }
                .keyboardShortcut("d", modifiers: [.shift, .command])
                .disabled(!canEdit)
            Divider()
            Button("Reply") { reply(.reply) }
                .keyboardShortcut("r")
                .disabled(!canReply)
            Button("Reply All") { reply(.replyAll) }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(!canReply)
            Button("Forward") { reply(.forward) }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(!canReply)
            Divider()
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
        CommandMenu("Format") {
            Group {
                Button("Bold") { compose?.editor?.toggleBold() }
                    .keyboardShortcut("b")
                Button("Italic") { compose?.editor?.toggleItalic() }
                    .keyboardShortcut("i")
                Button("Underline") { compose?.editor?.toggleUnderline() }
                    .keyboardShortcut("u")
                Divider()
                Button("Bulleted List") { compose?.editor?.toggleList(.bulleted) }
                Button("Numbered List") { compose?.editor?.toggleList(.numbered) }
                Divider()
                Button(compose?.format.link == true ? "Edit Link…" : "Add Link…") { compose?.isEditingLink = true }
                    .keyboardShortcut("k")
            }
            .disabled(!canEdit)
        }
    }

    /// A compose window is in front and its draft takes edits.
    private var canEdit: Bool {
        compose?.isEditable ?? false
    }

    /// Reply needs one conversation selected in the mailbox window, which is in front.
    private var canReply: Bool {
        compose == nil && (mailbox?.canReply ?? false)
    }

    private func reply(_ kind: ReplyKind) {
        guard let mailbox else { return }
        Task {
            guard let messageID = await mailbox.replyTargetMessageID() else { return }
            open(.reply(kind, messageID: messageID))
        }
    }

    /// Stops the newest send and reopens its window.
    private func undoSend() {
        guard let mailbox, let id = mailbox.undoableSendID else { return }
        Task {
            if await mailbox.undoSend(id) { openWindow(id: ComposeWindow.sceneID, value: id) }
        }
    }

    /// Opens a compose window once its draft exists. A failure shows in the mailbox window.
    private func open(_ start: MailboxModel.ComposeStart) {
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
