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

/// Menu bar commands. Shortcuts follow Apple Mail and live in `ShortcutCatalog`.
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
    @FocusedValue(\.calendarModel) private var calendar
    @FocusedValue(\.calendarActions) private var calendarActions
    @FocusedValue(\.readerActions) private var reader
    @FocusedValue(\.assistantModel) private var assistant
    @FocusedValue(\.attachmentLibraryToolbar) private var libraryToolbar

    var body: some Commands {
        ComposeFeatureCommands()
        MailViewCommands()
        fileCommands
        editCommands
        mailboxMenu
        messageMenu
        formatMenu
        CalendarCommands()
        goMenu
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts", systemImage: "keyboard") { openWindow(id: KeyboardShortcutsView.sceneID) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.keyboardShortcuts.shortcut)
        }
    }

    /// Add Account… joins the app menu; the rest fills File.
    @CommandsBuilder private var fileCommands: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Add Account…", systemImage: "person.crop.circle.badge.plus") { Task { await app.addAccount() } }
                .labelStyle(.titleAndIcon)
                .disabled(mailbox == nil || app.isSigningIn || !app.auth.isConfigured)
        }
        CommandGroup(replacing: .newItem) {
            // The Assistant window takes ⌘N for a new chat, so New Message steps back there.
            Button("New Message", systemImage: "square.and.pencil") { open(.newMessage) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.newMessage.shortcut)
                .disabled(mailbox == nil || assistant != nil)
            Button("New Chat", systemImage: "plus.bubble") { assistant?.newChat() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.newChat.shortcut)
                .disabled(assistant == nil)
            Button("New Event", systemImage: "calendar.badge.plus") {
                guard let calendar else { return }
                calendar.beginNew(on: calendar.date)
            }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.newEvent.shortcut)
                .disabled(!(calendar?.calendars.contains(where: \.canWrite) ?? false))
            Button("New Label…", systemImage: "tag") { focusedMailbox?.showNewLabel() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.newLabel.shortcut)
                .disabled(focusedMailbox == nil)
            Button("New Saved Search…", systemImage: "magnifyingglass") { focusedMailbox?.navigation.isCreatingSearch = true }
                .labelStyle(.titleAndIcon)
                .disabled(focusedMailbox == nil)
            Divider()
            Button("Open Conversation", systemImage: "envelope.open") { openConversationWindow() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.openConversation.shortcut)
                .disabled(focusedMailbox?.selectedThreadIDs.count != 1)
            Button("Attach Files…", systemImage: "paperclip") { compose?.isChoosingFiles = true }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.attachFiles.shortcut)
                .disabled(!canEdit)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…", systemImage: "printer") { printFocusedContent(asPDF: false) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.print.shortcut)
                .disabled(!canPrint)
            Button("Export as PDF…", systemImage: "doc.richtext") { printFocusedContent(asPDF: true) }
                .labelStyle(.titleAndIcon)
                .disabled(!(reader?.canPrint ?? false))
        }
    }

    @CommandsBuilder private var editCommands: some Commands {
        CommandGroup(after: .undoRedo) {
            // Compose windows can still send while the session has expired,
            // and the mailbox window, showing sign-in, has no Undo then.
            Button("Undo Send", systemImage: "arrow.uturn.backward") { undoSend() }
                .labelStyle(.titleAndIcon)
                .disabled(app.mailbox?.undoableSendID == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…", systemImage: "magnifyingglass") { find() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.find.shortcut)
                .disabled(reader == nil && calendarActions == nil && libraryToolbar == nil)
            Button("Search Mail", systemImage: "magnifyingglass") { focusedMailbox?.search.focusField() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.searchMail.shortcut)
                .disabled(focusedMailbox == nil)
        }
    }

    private var mailboxMenu: some Commands {
        CommandMenu("Mailbox") {
            Button("Check for New Mail", systemImage: "arrow.clockwise") { mailbox?.syncNow() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.checkForNewMail.shortcut)
                .disabled(mailbox == nil)
            Button("Mark All as Read", systemImage: "envelope.open") { focusedMailbox?.triage.markAllRead() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.markAllRead.shortcut)
                .disabled(!canMarkAllRead)
            Divider()
            if let focusedMailbox, let permanentMailbox {
                Button(permanentMailbox == SystemLabel.trash ? "Empty Trash…" : "Delete All Spam…",
                       systemImage: "trash.slash", role: .destructive) {
                    Task { await focusedMailbox.triage.preparePermanentDeletion(entireMailbox: true) }
                }
                    .labelStyle(.titleAndIcon)
                    .disabled(focusedMailbox.triage.isPreparing || focusedMailbox.triage.isDeleting)
                Button("Delete Forever…", systemImage: "trash.slash", role: .destructive) {
                    Task { await focusedMailbox.triage.preparePermanentDeletion() }
                }
                    .labelStyle(.titleAndIcon)
                    .disabled(!hasSelection || focusedMailbox.triage.isPreparing || focusedMailbox.triage.isDeleting)
                Divider()
            }
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
    }

    private var messageMenu: some Commands {
        CommandMenu("Message") {
            Button("Send", systemImage: "paperplane") { Task { await compose?.send() } }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.send.shortcut)
                .disabled(!canEdit)
            Divider()
            Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(.reply) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.reply.shortcut)
                .disabled(!canReply)
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { reply(.replyAll) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.replyAll.shortcut)
                .disabled(!canReply)
            Button("Forward", systemImage: "arrowshape.turn.up.right") { reply(.forward) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.forward.shortcut)
                .disabled(!canReply)
            Button("Forward as Attachment", systemImage: "arrowshape.turn.up.right.fill") { forwardAsAttachment() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.forwardAsAttachment.shortcut)
                .disabled(!canReply)
            Divider()
            Button(countedTitle(verb: "Archive"), systemImage: "archivebox") { performMailAction(.archive) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.archive.shortcut)
                .disabled(conversationLink == nil && !(focusedMailbox?.canArchive ?? false))
            Button(countedTitle(verb: "Move", suffix: "to Trash"), systemImage: "trash") { performMailAction(.trash) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.moveToTrash.shortcut)
                .disabled(conversationLink == nil && !(focusedMailbox?.canTrash ?? false))
            Button(isSpamMailbox ? "Not Spam" : "Report Spam", systemImage: isSpamMailbox ? "checkmark.shield" : "xmark.bin") {
                focusedMailbox?.triage.perform(isSpamMailbox ? .notSpam : .spam)
            }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.toggleSpam.shortcut)
                .disabled(!canTriage)
            Divider()
            Button(isRead ? "Mark as Unread" : "Mark as Read", systemImage: isRead ? "envelope.badge" : "envelope.open") { focusedMailbox?.toggleRead() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.toggleRead.shortcut)
                .disabled(!hasSelection)
            Button(isStarred ? "Remove Star" : "Star", systemImage: isStarred ? "star.fill" : "star") { focusedMailbox?.toggleStar() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.toggleStar.shortcut)
                .disabled(!hasSelection)
            Button("Mark as Important", systemImage: "exclamationmark") { focusedMailbox?.triage.perform(.important) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.markImportant.shortcut)
                .disabled(!canTriage)
            Button("Mark as Not Important", systemImage: "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90") {
                focusedMailbox?.triage.perform(.notImportant)
            }
                .labelStyle(.titleAndIcon)
                .disabled(!canTriage)
            Divider()
            Button("Edit Labels…", systemImage: "tag") { focusedMailbox?.showEditLabels() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.editLabels.shortcut)
                .disabled(!hasSelection)
            Button("Move to…", systemImage: "folder") { focusedMailbox?.showMoveTo() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.moveTo.shortcut)
                .disabled(!hasSelection)
            Divider()
            // A disabled submenu still opens from the menu bar, so with nothing
            // to act on, Snooze and Share are plain disabled items.
            if canSnooze {
                Menu {
                    SnoozeMenuItems(
                        onSnooze: { focusedMailbox?.snooze(until: $0) },
                        onChooseDate: { focusedMailbox?.showSnoozeDate() }
                    )
                } label: {
                    Label("Snooze", systemImage: "clock")
                        .labelStyle(.titleAndIcon)
                }
            } else {
                Button("Snooze", systemImage: "clock") {}
                    .labelStyle(.titleAndIcon)
                    .disabled(true)
            }
            // A shortcut can't open the submenu, so it opens Choose Date & Time.
            Button("Snooze…", systemImage: "clock") { focusedMailbox?.showSnoozeDate() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.snooze.shortcut)
                .disabled(!canSnooze)
            if focusedMailbox?.showsSnoozed ?? false {
                Button("Unsnooze", systemImage: "clock.arrow.circlepath") { focusedMailbox?.unsnooze() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!hasSelection)
            }
            Divider()
            Button("Copy Link", systemImage: "link") { copyLink() }
                .labelStyle(.titleAndIcon)
                .disabled(selectedLink?.ternURL == nil)
            Button("Open in Gmail", systemImage: "safari") { if let gmailURL { NSWorkspace.shared.open(gmailURL) } }
                .labelStyle(.titleAndIcon)
                .disabled(gmailURL == nil)
            // Share opens the share picker, so its title ends in an ellipsis.
            if let shareFile {
                ShareLink(item: shareFile, preview: shareFile.preview) {
                    Label("Share…", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                }
            } else {
                Button("Share…", systemImage: "square.and.arrow.up") {}
                    .labelStyle(.titleAndIcon)
                    .disabled(true)
            }
        }
    }

    /// Share sends the selected message, or the one with selected text, or
    /// else the conversation's newest message that isn't a draft. The file is
    /// fetched only when a service asks for it, so the menu never waits.
    private var shareFile: MessageFileItem? {
        guard let link = selectedLink, let mailbox = focusedMailbox ?? (conversationLink == nil ? nil : app.mailbox),
              mailbox.account(id: link.accountID) != nil else { return nil }
        let quote = selectedQuote.flatMap {
            $0.belongsTo(accountID: link.accountID, threadID: link.threadID, messageID: link.messageID) ? $0.messageID : nil
        }
        let thread = mailbox.listedThreads.first(where: { $0.accountID == link.accountID && $0.id == link.threadID })
        return MessageFileItem(link: link, preferredMessageID: quote, previewTitle: thread?.subject, mailbox: mailbox)
    }

    private var formatMenu: some Commands {
        CommandMenu("Format") {
            Group {
                Button("Bold", systemImage: "bold") { formattingEditor?.toggleBold() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut(ShortcutCatalog.bold.shortcut)
                Button("Italic", systemImage: "italic") { formattingEditor?.toggleItalic() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut(ShortcutCatalog.italic.shortcut)
                Button("Underline", systemImage: "underline") { formattingEditor?.toggleUnderline() }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut(ShortcutCatalog.underline.shortcut)
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
                    .keyboardShortcut(ShortcutCatalog.link.shortcut)
            }
            .disabled(settingsEditor == nil && !(compose?.canFormat ?? false))
        }
    }

    private var goMenu: some Commands {
        CommandMenu("Go") {
            Button("Mail", systemImage: "envelope") {
                app.destination = .mail
                if mailbox?.selectedLabelID == AttachmentLibraryModel.mailboxID { mailbox?.go(to: SystemLabel.inbox) }
            }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.goMail.shortcut)
                .disabled(!isMainWindowFocused)
            Button("Calendar", systemImage: "calendar") { app.destination = .calendar }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.goCalendar.shortcut)
                .disabled(!isMainWindowFocused)
            Button("Attachments", systemImage: "paperclip") {
                app.destination = .mail
                mailbox?.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)
            }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.goAttachments.shortcut)
                .disabled(!isMainWindowFocused)
            Divider()
            Button("Go to Label…", systemImage: "tag") { focusedMailbox?.navigation.isShowingSwitcher = true }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.goToLabel.shortcut)
                .disabled(focusedMailbox == nil)
            Divider()
            Button("Analytics", systemImage: "chart.bar.xaxis") {
                openWindow(id: MailAnalyticsWindow.sceneID, value: MailAnalyticsRoute())
            }
            .labelStyle(.titleAndIcon)
            .disabled(mailbox == nil)
            Divider()
            ForEach(Array(zip(SystemMailbox.numbered, ShortcutCatalog.mailboxes)), id: \.0.id) { box, command in
                Button(box.title, systemImage: box.systemImage) { focusedMailbox?.go(to: box.id) }
                    .labelStyle(.titleAndIcon)
                    .keyboardShortcut(command.shortcut)
                    .disabled(focusedMailbox == nil)
            }
            Button("All Mail", systemImage: "archivebox") { focusedMailbox?.go(to: SystemLabel.allMail) }
                .labelStyle(.titleAndIcon)
                .disabled(focusedMailbox == nil)
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

    private var canPrint: Bool {
        (reader?.canPrint ?? false) || (calendarActions != nil && calendar?.events.isEmpty == false)
    }

    private var isMainWindowFocused: Bool { isMainWindow == true && mailbox != nil }

    private var isSpamMailbox: Bool { focusedMailbox?.selectedLabelID == SystemLabel.spam }

    /// Trash and Spam are the only mailboxes that delete for good.
    private var permanentMailbox: String? {
        guard let id = focusedMailbox?.selectedLabelID, id == SystemLabel.trash || id == SystemLabel.spam else { return nil }
        return id
    }

    private var canTriage: Bool {
        guard let focusedMailbox, hasSelection else { return false }
        return !focusedMailbox.triage.isPreparing && !focusedMailbox.triage.isDeleting
    }

    private var canMarkAllRead: Bool {
        guard let focusedMailbox else { return false }
        let id = focusedMailbox.selectedLabelID
        return !focusedMailbox.search.isActive && id != MailboxModel.snoozedID && id != MailboxModel.outboxID
            && !focusedMailbox.triage.isPreparing && !focusedMailbox.triage.isDeleting
    }

    /// "Archive 3 Conversations" when more than one is selected.
    private func countedTitle(verb: String, suffix: String? = nil) -> String {
        let count = focusedMailbox?.selectedListRowIDs.count ?? 0
        let noun = focusedMailbox?.listPreferences.conversations == false ? "Messages" : "Conversations"
        var title = count > 1 ? "\(verb) \(count) \(noun)" : verb
        if let suffix { title += " \(suffix)" }
        return title
    }

    /// The one selected conversation, or the open conversation window's.
    private var selectedLink: MailLink? {
        if let conversationLink { return conversationLink }
        guard let mailbox = focusedMailbox, mailbox.selectedThreadIDs.count == 1, let key = mailbox.selectedThreadIDs.first else { return nil }
        let messageID = mailbox.listPreferences.conversations ? nil : mailbox.selectedMessageRows.first?.messageID
        return MailLink(accountID: key.accountID, threadID: key.threadID, messageID: messageID)
    }

    private var gmailURL: URL? {
        guard let link = selectedLink, let email = app.mailbox?.account(id: link.accountID)?.account.email else { return nil }
        return link.gmailURL(email: email)
    }

    private func copyLink() {
        guard let url = selectedLink?.ternURL else { return }
        NSPasteboard.general.replaceContents(with: url.absoluteString)
    }

    private func openConversationWindow() {
        guard let mailbox = focusedMailbox, let key = mailbox.selectedThreadIDs.first, mailbox.selectedThreadIDs.count == 1 else { return }
        let messageID = mailbox.listPreferences.conversations ? nil : mailbox.selectedMessageRows.first?.messageID
        openWindow(id: ConversationWindow.sceneID, value: MailLink(accountID: key.accountID, threadID: key.threadID, messageID: messageID))
    }

    private func printFocusedContent(asPDF: Bool) {
        if let reader, reader.canPrint {
            reader.print(asPDF)
        } else if !asPDF {
            calendarActions?.print()
        }
    }

    /// ⌘F finds in the open conversation, or focuses the search of the
    /// destination that has one.
    private func find() {
        if let reader {
            reader.find()
        } else if let libraryToolbar {
            libraryToolbar.searchFocusRequest += 1
        } else {
            calendarActions?.find()
        }
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

    /// Forwards the newest message of the selected conversation as a file.
    private func forwardAsAttachment() {
        guard let mailbox = focusedMailbox ?? (conversationLink == nil ? nil : app.mailbox) else { return }
        Task {
            let target: (messageID: String, accountID: String)?
            if let link = conversationLink {
                target = await mailbox.nativeReplyMessageID(for: link, preferredMessageID: nil).map { ($0, link.accountID) }
            } else if case .reply(_, let messageID, let accountID)? = await mailbox.replyStart(.forward) {
                target = (messageID, accountID)
            } else {
                target = nil
            }
            guard let target,
                  let id = await mailbox.startForwardingAttachment(messageID: target.messageID, accountID: target.accountID) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }

    private func performMailAction(_ action: MailAction) {
        // ⌘⌫ while typing deletes to the start of the line, as in every Mac text field.
        if action == .trash, NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
            return
        }
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
