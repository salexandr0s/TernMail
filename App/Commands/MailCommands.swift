import MailStore
import MessageContent
import SwiftUI

/// Menu bar commands. Shortcuts follow Apple Mail.
struct MailCommands: Commands {
    let app: AppModel
    // Tern has one mailbox window. Its commands remain available when focus
    // moves between a list, WebKit and the menu bar. While the session has
    // expired the window shows sign-in, so they are off.
    var mailbox: MailboxModel? {
        guard case .signedIn = app.phase else { return nil }
        return app.mailbox
    }
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.composeModel) private var compose

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message", systemImage: "square.and.pencil") { open(.newMessage) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("n")
                .disabled(mailbox == nil)
            Button("Attach Files…", systemImage: "paperclip") { compose?.isChoosingFiles = true }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("a", modifiers: [.shift, .command])
                .disabled(!canEdit)
            Divider()
            Button("Add Account…", systemImage: "person.crop.circle.badge.plus") { Task { await app.addAccount() } }
                .labelStyle(.titleAndIcon)
                .disabled(mailbox == nil || app.isSigningIn)
        }
        CommandGroup(after: .undoRedo) {
            // Compose windows can still send while the session has expired,
            // and the mailbox window, showing sign-in, has no Undo then.
            Button("Undo Send", systemImage: "arrow.uturn.backward") { undoSend() }
                .labelStyle(.titleAndIcon)
                .disabled(app.mailbox?.undoableSendID == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Mail", systemImage: "magnifyingglass") { mailbox?.search.focusField() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("f", modifiers: [.option, .command])
                .disabled(mailbox == nil || compose != nil)
        }
        CommandMenu("Message") {
            Button("Send", systemImage: "paperplane") { Task { await compose?.send() } }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("d", modifiers: [.shift, .command])
                .disabled(!canEdit)
            Divider()
            Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(.reply) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("r")
                .disabled(!canReply)
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { reply(.replyAll) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(!canReply)
            Button("Forward", systemImage: "arrowshape.turn.up.right") { reply(.forward) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(!canReply)
            Divider()
            Button("Archive", systemImage: "archivebox") { mailbox?.perform(.archive) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(compose != nil || !(mailbox?.canArchive ?? false))
            // In a compose window ⌘⌫ deletes to the start of the line instead.
            Button("Move to Trash", systemImage: "trash") { mailbox?.perform(.trash) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(compose != nil || !(mailbox?.canTrash ?? false))
            Divider()
            Button(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open") { mailbox?.toggleRead() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("u", modifiers: [.shift, .command])
                .disabled(!hasSelection)
            Button(isStarred ? "Remove Star" : "Star", systemImage: isStarred ? "star.fill" : "star") { mailbox?.toggleStar() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("l", modifiers: [.shift, .command])
                .disabled(!hasSelection)
            Divider()
            Button("Edit Labels…", systemImage: "tag") { mailbox?.showEditLabels() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("l", modifiers: [.option, .command])
                .disabled(!hasSelection)
            Button("Move to…", systemImage: "folder") { mailbox?.showMoveTo() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("m", modifiers: [.control, .command])
                .disabled(!hasSelection)
            Divider()
            Menu {
                SnoozeMenuItems(
                    onSnooze: { mailbox?.snooze(until: $0) },
                    onChooseDate: { mailbox?.showSnoozeDate() }
                )
            } label: {
                Label("Snooze", systemImage: "clock")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!canSnooze)
            // A shortcut can't open the submenu, so it opens Choose Date & Time.
            Button("Snooze…", systemImage: "clock") { mailbox?.showSnoozeDate() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("b", modifiers: [.control, .command])
                .disabled(!canSnooze)
            if mailbox?.showsSnoozed ?? false {
                Button("Unsnooze", systemImage: "clock.arrow.circlepath") { mailbox?.unsnooze() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!hasSelection)
            }
        }
        CommandMenu("Mailbox") {
            Button("Check for New Mail", systemImage: "arrow.clockwise") { mailbox?.syncNow() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("n", modifiers: [.shift, .command])
                .disabled(mailbox == nil)
            Button("New Label…", systemImage: "tag") { mailbox?.showNewLabel() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("n", modifiers: [.option, .command])
                .disabled(mailbox == nil || compose != nil)
            Divider()
            if let mailbox, mailbox.hasSeveralAccounts {
                Menu {
                    ForEach(mailbox.accounts, id: \.account.id) { owner in
                        Button("\(owner.account.email)…", systemImage: "person.crop.circle") { app.accountToSignOut = owner.account }
                            .labelStyle(.titleAndIcon)
                    }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Button("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right") { app.isConfirmingSignOut = true }
                    .labelStyle(.titleAndIcon)
                    .disabled(!app.canSignOut)
            }
        }
        CommandMenu("Go") {
            // In the sidebar's order, so each number matches a row.
            ForEach(Array(SystemMailbox.numbered.enumerated()), id: \.element.id) { index, box in
                Button(box.title, systemImage: box.systemImage) { mailbox?.go(to: box.id) }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(mailbox == nil || compose != nil)
            }
            Button("All Mail", systemImage: "archivebox") { mailbox?.go(to: SystemLabel.allMail) }
                .labelStyle(.titleAndIcon)
                .disabled(mailbox == nil || compose != nil)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts", systemImage: "keyboard") { openWindow(id: KeyboardShortcutsView.sceneID) }
                .labelStyle(.titleAndIcon)
        }
        CommandMenu("Format") {
            Group {
                Button("Bold", systemImage: "bold") { compose?.editor?.toggleBold() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("b")
                Button("Italic", systemImage: "italic") { compose?.editor?.toggleItalic() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("i")
                Button("Underline", systemImage: "underline") { compose?.editor?.toggleUnderline() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("u")
                Divider()
                Button("Bulleted List", systemImage: "list.bullet") { compose?.editor?.toggleList(.bulleted) }
                    .labelStyle(.titleAndIcon)
                Button("Numbered List", systemImage: "list.number") { compose?.editor?.toggleList(.numbered) }
                    .labelStyle(.titleAndIcon)
                Divider()
                Button(compose?.format.link == true ? "Edit Link…" : "Add Link…", systemImage: "link") { compose?.isEditingLink = true }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("k")
            }
            .disabled(!(compose?.canFormat ?? false))
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
            guard let start = await mailbox.replyStart(kind) else { return }
            open(start)
        }
    }

    /// Stops the newest send and reopens its window.
    private func undoSend() {
        guard let mailbox = app.mailbox, let id = mailbox.undoableSendID else { return }
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

    /// Conversations are selected in the mailbox window, which is in front.
    private var hasSelection: Bool {
        compose == nil && !(mailbox?.selectedThreadIDs.isEmpty ?? true)
    }

    private var canSnooze: Bool {
        compose == nil && (mailbox?.canSnooze ?? false)
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
