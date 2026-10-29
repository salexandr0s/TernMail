import AppKit
import MailStore
import MessageContent
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    let mailbox: MailboxModel

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView(mailbox: mailbox)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            Group {
                if mailbox.selectedLabelID == MailboxModel.outboxID, !mailbox.search.isActive {
                    OutboxView(mailbox: mailbox)
                } else {
                    ThreadListView(mailbox: mailbox)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: newMessage) {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                    .help("New Message")
                }
            }
        } detail: {
            DetailView(mailbox: mailbox)
                .toolbar { MailToolbar(mailbox: mailbox, reply: reply) }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: Tokens.Space.s2) {
                if let notice = mailbox.sendNotice {
                    NoticeView(notice: notice) {
                        if let undo = notice.undo { self.undo(undo) }
                    } onDismiss: {
                        if mailbox.sendNotice?.id == notice.id { mailbox.sendNotice = nil }
                    }
                    .transition(.opacity)
                    .id(notice.id)
                }
                if let notice = mailbox.notice {
                    NoticeView(notice: notice) {
                        if let undo = notice.undo { self.undo(undo) }
                    } onDismiss: {
                        if mailbox.notice?.id == notice.id { mailbox.notice = nil }
                    }
                    .transition(.opacity)
                    .id(notice.id)
                }
            }
            .padding(Tokens.Space.s4)
        }
        .background {
            ShortcutMonitor(isEnabled: usesSingleKeys, perform: perform)
        }
        .animation(Tokens.Motion.standard(), value: mailbox.notice)
        .animation(Tokens.Motion.standard(), value: mailbox.sendNotice)
        .onAppear { mailbox.undoManager = undoManager }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mailbox.syncNow()
        }
        .confirmationDialog("Sign out of Tern?", isPresented: $app.isConfirmingSignOut) {
            Button("Sign Out", role: .destructive) {
                Task { await app.signOut() }
            }
        } message: {
            Text(app.signOutMessage)
        }
        .confirmationDialog(
            "Sign out of \(app.accountToSignOut?.email ?? "this account")?",
            isPresented: Binding(get: { app.accountToSignOut != nil }, set: { if !$0 { app.accountToSignOut = nil } }),
            presenting: app.accountToSignOut
        ) { account in
            Button("Sign Out", role: .destructive) {
                Task { await app.signOut(of: account.id) }
            }
        } message: { account in
            Text(app.signOutMessage(for: account))
        }
        .onChange(of: mailbox.draftToReopen) { _, id in
            guard let id else { return }
            mailbox.draftToReopen = nil
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }

    private func newMessage() {
        Task {
            guard let id = await mailbox.startCompose(.newMessage) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }

    /// A single-key shortcut does what its menu command does, when that is
    /// enabled. Returns false when it does nothing, so the key goes on to the
    /// focused view: Return with a selection reaches the list, for one.
    private func perform(_ action: SingleKeyShortcuts.Action) -> Bool {
        guard canPerform(action) else { return false }
        switch action {
        case .nextConversation: mailbox.selectAdjacentThread(1)
        case .previousConversation: mailbox.selectAdjacentThread(-1)
        case .openConversation: mailbox.selectAdjacentThread(1)
        case .archive: mailbox.perform(.archive)
        case .trash: mailbox.perform(.trash)
        case .toggleStar: mailbox.toggleStar()
        case .markRead: mailbox.perform(.markRead)
        case .markUnread: mailbox.perform(.markUnread)
        case .editLabels: mailbox.showEditLabels()
        case .moveTo: mailbox.showMoveTo()
        case .snooze: mailbox.showSnoozeDate()
        case .search: mailbox.search.focusField()
        case .newMessage: newMessage()
        case .reply: reply(.reply)
        case .replyAll: reply(.replyAll)
        case .forward: reply(.forward)
        case .undo: undoManager?.undo()
        case .showShortcuts: openWindow(id: KeyboardShortcutsView.sceneID)
        case .go(let destination): mailbox.go(to: Self.labelID(of: destination))
        }
        return true
    }

    private func canPerform(_ action: SingleKeyShortcuts.Action) -> Bool {
        let hasSelection = !mailbox.selectedThreadIDs.isEmpty
        switch action {
        case .openConversation: return !hasSelection
        case .archive: return mailbox.canArchive
        case .trash: return mailbox.canTrash
        case .toggleStar, .markRead, .markUnread, .editLabels, .moveTo: return hasSelection
        case .snooze: return mailbox.canSnooze
        case .undo: return undoManager?.canUndo == true
        case .nextConversation, .previousConversation, .search, .newMessage, .reply, .replyAll, .forward,
             .showShortcuts, .go:
            return true
        }
    }

    private func reply(_ kind: ReplyKind) {
        Task {
            guard let start = await mailbox.replyStart(kind), let id = await mailbox.startCompose(start) else { return }
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
    }

    private static func labelID(of destination: SingleKeyShortcuts.Destination) -> String {
        switch destination {
        case .inbox: SystemLabel.inbox
        case .starred: SystemLabel.starred
        case .snoozed: MailboxModel.snoozedID
        case .drafts: SystemLabel.draft
        case .sent: SystemLabel.sent
        case .allMail: SystemLabel.allMail
        }
    }

    /// Undoing a send or a discard reopens the message's window.
    private func undo(_ undo: MailboxModel.Notice.Undo) {
        switch undo {
        case .action(let row):
            mailbox.undo(row)
        case .send(let id):
            Task { if await mailbox.undoSend(id) { openWindow(id: ComposeWindow.sceneID, value: id) } }
        case .discard(let id):
            Task { if await mailbox.undoDiscard(id) { openWindow(id: ComposeWindow.sceneID, value: id) } }
        }
    }
}

private struct DetailView: View {
    let mailbox: MailboxModel

    var body: some View {
        let ids = mailbox.selectedThreadIDs
        if mailbox.selectedLabelID == MailboxModel.outboxID, !mailbox.search.isActive {
            ContentUnavailableView(
                "Outbox",
                systemImage: "tray.and.arrow.up",
                description: Text("Messages wait here until Gmail has them. Double-click one to open it.")
            )
        } else if ids.count == 1, let key = ids.first {
            ThreadView(key: key, mailbox: mailbox)
                .id(key)
        } else if ids.count > 1 {
            ContentUnavailableView("\(ids.count) Conversations Selected", systemImage: "square.stack")
        } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "envelope")
        }
    }
}
