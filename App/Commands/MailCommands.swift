import AppKit
import MailStore
import MessageContent
import SyncEngine
import SwiftUI

extension FocusedValues {
    /// The mailbox scene remains focused across its list, toolbar and WebKit.
    @Entry var mailboxModel: MailboxModel?
    /// Account confirmations belong to the main window, including reauthentication.
    @Entry var isMainWindow: Bool?
}

/// Menu bar commands. Shortcuts follow Apple Mail.
struct MailCommands: Commands {
    let app: AppModel
    // App-level commands can use the open mailbox from any window. Selection
    // and navigation commands use the focused mailbox scene below.
    var mailbox: MailboxModel? {
        guard case .signedIn = app.phase else { return nil }
        return app.mailbox
    }
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.composeModel) private var compose
    @FocusedValue(\.settingsEditor) private var settingsEditor
    @FocusedValue(\.mailboxModel) private var focusedMailbox
    @FocusedValue(\.isMainWindow) private var isMainWindow
    @FocusedValue(\.selectedMailQuote) private var selectedQuote
    @FocusedValue(\.conversationLink) private var conversationLink

    var body: some Commands {
        ComposeFeatureCommands()
        MailViewCommands()
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
                .disabled(mailbox == nil || app.isSigningIn || !app.auth.isConfigured)
        }
        CommandGroup(after: .undoRedo) {
            // Compose windows can still send while the session has expired,
            // and the mailbox window, showing sign-in, has no Undo then.
            Button("Undo Send", systemImage: "arrow.uturn.backward") { undoSend() }
                .labelStyle(.titleAndIcon)
                .disabled(app.mailbox?.undoableSendID == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Search Mail", systemImage: "magnifyingglass") { focusedMailbox?.search.focusField() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("f", modifiers: [.option, .command])
                .disabled(focusedMailbox == nil)
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
            Button("Archive", systemImage: "archivebox") { performMailAction(.archive) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(conversationLink == nil && !(focusedMailbox?.canArchive ?? false))
            // In a compose window ⌘⌫ deletes to the start of the line instead.
            Button("Move to Trash", systemImage: "trash") { performMailAction(.trash) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(conversationLink == nil && !(focusedMailbox?.canTrash ?? false))
            Divider()
            Button(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open") { focusedMailbox?.toggleRead() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("u", modifiers: [.shift, .command])
                .disabled(!hasSelection)
            Button(isStarred ? "Remove Star" : "Star", systemImage: isStarred ? "star.fill" : "star") { focusedMailbox?.toggleStar() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("l", modifiers: [.shift, .command])
                .disabled(!hasSelection)
            Divider()
            Button("Edit Labels…", systemImage: "tag") { focusedMailbox?.showEditLabels() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("l", modifiers: [.option, .command])
                .disabled(!hasSelection)
            Button("Move to…", systemImage: "folder") { focusedMailbox?.showMoveTo() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("m", modifiers: [.control, .command])
                .disabled(!hasSelection)
            Divider()
            Menu {
                SnoozeMenuItems(
                    onSnooze: { focusedMailbox?.snooze(until: $0) },
                    onChooseDate: { focusedMailbox?.showSnoozeDate() }
                )
            } label: {
                Label("Snooze", systemImage: "clock")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!canSnooze)
            // A shortcut can't open the submenu, so it opens Choose Date & Time.
            Button("Snooze…", systemImage: "clock") { focusedMailbox?.showSnoozeDate() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("b", modifiers: [.control, .command])
                .disabled(!canSnooze)
            if focusedMailbox?.showsSnoozed ?? false {
                Button("Unsnooze", systemImage: "clock.arrow.circlepath") { focusedMailbox?.unsnooze() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!hasSelection)
            }
        }
        CommandMenu("Mailbox") {
            Button("Check for New Mail", systemImage: "arrow.clockwise") { mailbox?.syncNow() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("n", modifiers: [.shift, .command])
                .disabled(mailbox == nil)
            Button("New Label…", systemImage: "tag") { focusedMailbox?.showNewLabel() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("n", modifiers: [.option, .command])
                .disabled(focusedMailbox == nil)
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
                .disabled(!canSignOut)
            } else {
                Button("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right") { app.isConfirmingSignOut = true }
                    .labelStyle(.titleAndIcon)
                    .disabled(!canSignOut)
            }
        }
        CommandMenu("Go") {
            Button("Go to Label…", systemImage: "tag") { focusedMailbox?.navigation.isShowingSwitcher = true }
                .keyboardShortcut("l", modifiers: [.control, .option, .command])
                .disabled(focusedMailbox == nil)
            Divider()
            // In the sidebar's order, so each number matches a row.
            ForEach(Array(SystemMailbox.numbered.enumerated()), id: \.element.id) { index, box in
                Button(box.title, systemImage: box.systemImage) { focusedMailbox?.go(to: box.id) }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(focusedMailbox == nil)
            }
            Button("All Mail", systemImage: "archivebox") { focusedMailbox?.go(to: SystemLabel.allMail) }
                .labelStyle(.titleAndIcon)
                .disabled(focusedMailbox == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts", systemImage: "keyboard") { openWindow(id: KeyboardShortcutsView.sceneID) }
                .labelStyle(.titleAndIcon)
        }
        CommandMenu("Format") {
            Group {
                Button("Bold", systemImage: "bold") { formattingEditor?.toggleBold() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("b")
                Button("Italic", systemImage: "italic") { formattingEditor?.toggleItalic() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("i")
                Button("Underline", systemImage: "underline") { formattingEditor?.toggleUnderline() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("u")
                Divider()
                Button("Bulleted List", systemImage: "list.bullet") { formattingEditor?.toggleList(.bulleted) }
                    .labelStyle(.titleAndIcon)
                Button("Numbered List", systemImage: "list.number") { formattingEditor?.toggleList(.numbered) }
                    .labelStyle(.titleAndIcon)
                Divider()
                Button((settingsEditor?.format.link ?? compose?.format.link) == true ? "Edit Link…" : "Add Link…", systemImage: "link") {
                    if let settingsEditor { settingsEditor.editLink() }
                    else { compose?.isEditingLink = true }
                }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut("k")
            }
            .disabled(settingsEditor == nil && !(compose?.canFormat ?? false))
        }
    }

    private var formattingEditor: (any RichTextEditing)? { settingsEditor?.editor ?? compose?.editor }

    /// A compose window is in front and its draft takes edits.
    private var canEdit: Bool {
        compose?.isEditable ?? false
    }

    /// Reply needs one conversation selected in the mailbox window, which is in front.
    private var canReply: Bool {
        if let conversationLink { return app.mailbox?.account(id: conversationLink.accountID) != nil }
        return focusedMailbox?.canReply ?? false
    }

    private func reply(_ kind: ReplyKind) {
        guard let mailbox = focusedMailbox ?? (conversationLink == nil ? nil : app.mailbox) else { return }
        Task {
            if let link = conversationLink {
                let quote = selectedQuote.flatMap { $0.belongsTo(accountID: link.accountID, threadID: link.threadID,
                    messageID: link.messageID) ? $0 : nil }
                guard let messageID = await mailbox.nativeReplyMessageID(for: link, preferredMessageID: quote?.messageID),
                    let id = await mailbox.requestReply(kind, messageID: messageID,
                    accountID: link.accountID, selectedText: quote?.text) else { return }
                openWindow(id: ComposeWindow.sceneID, value: id)
                return
            }
            if let key = mailbox.selectedThreadIDs.first, mailbox.selectedThreadIDs.count == 1,
               let quote = selectedQuote, quote.belongsTo(accountID: key.accountID, threadID: key.threadID,
                messageID: mailbox.listPreferences.conversations ? nil : mailbox.selectedMessageRows.first?.messageID) {
                guard let id = await mailbox.requestReply(kind, messageID: quote.messageID,
                    accountID: quote.accountID, selectedText: quote.text) else { return }
                openWindow(id: ComposeWindow.sceneID, value: id)
                return
            }
            guard let start = await mailbox.replyStart(kind) else { return }
            open(start)
        }
    }

    private func performMailAction(_ action: MailAction) {
        if let link = conversationLink, let mailbox = app.mailbox {
            let manager = NSApp.keyWindow?.undoManager
            Task { await mailbox.performNativeAction(action, link: link, undoManager: manager) }
        } else { focusedMailbox?.perform(action) }
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
        !(focusedMailbox?.selectedThreadIDs.isEmpty ?? true)
    }

    private var canSnooze: Bool {
        focusedMailbox?.canSnooze ?? false
    }

    private var canSignOut: Bool {
        app.canSignOut && isMainWindow == true
    }

    private var isRead: Bool {
        guard let mailbox = focusedMailbox else { return false }
        return mailbox.allRead(mailbox.selectedThreadIDs)
    }

    private var isStarred: Bool {
        guard let mailbox = focusedMailbox else { return false }
        return mailbox.allStarred(mailbox.selectedThreadIDs)
    }
}
