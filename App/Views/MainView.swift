import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    let mailbox: MailboxModel

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView(mailbox: mailbox)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            ThreadListView(mailbox: mailbox)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        } detail: {
            DetailView(mailbox: mailbox)
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
            Text("Tern deletes the mail it downloaded and any changes it hasn't sent to Gmail yet.")
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
        if ids.count == 1, let id = ids.first {
            ThreadView(threadID: id, mailbox: mailbox)
                .id(id)
        } else if ids.count > 1 {
            ContentUnavailableView("\(ids.count) Conversations Selected", systemImage: "square.stack")
        } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "envelope")
        }
    }
}
