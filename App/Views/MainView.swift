import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
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
            if let notice = mailbox.notice {
                NoticeView(notice: notice) {
                    if let row = notice.undo { mailbox.undo(row) }
                } onDismiss: {
                    if mailbox.notice?.id == notice.id { mailbox.notice = nil }
                }
                .padding(Tokens.Space.s4)
                .transition(.opacity)
                .id(notice.id)
            }
        }
        .animation(Tokens.Motion.standard(), value: mailbox.notice)
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
