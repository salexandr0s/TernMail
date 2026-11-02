import SwiftUI

/// Toolbar changes leave the column closures unchanged. The descendants still
/// observe mailbox updates and the bindings keep this window's layout editable.
struct MailColumnsContent: View, Equatable {
    struct Identity: Equatable, Sendable {
        let columnVisibility: NavigationSplitViewVisibility
        let showsReader: Bool
        let showsAssistant: Bool
        let topInset: CGFloat
        let outboxFocused: Bool
    }

    let mailbox: MailboxModel
    let identity: Identity
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var sidebarColumnWidth: CGFloat
    @FocusState.Binding var outboxFocused: Bool
    let paneSizing: AssistantMailPaneSizing
    let toolbarInset: ClippedSplitToolbarInset

    // Compare immutable snapshots, not two bindings that both read today's
    // value. The sizing objects identify the window that owns those bindings.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mailbox === rhs.mailbox && lhs.identity == rhs.identity
            && lhs.paneSizing === rhs.paneSizing && lhs.toolbarInset === rhs.toolbarInset
    }

    private var showsOutbox: Bool {
        mailbox.selectedLabelID == MailboxModel.outboxID && !mailbox.search.isActive
    }

    var body: some View {
        MailWorkspaceColumns(columnVisibility: $columnVisibility, showsReader: identity.showsReader) {
            SidebarView(mailbox: mailbox)
                // AppKit asserts when the system toggle, or any item over the sidebar
                // column, meets a saved customizable toolbar or a second window, so
                // the content toolbar carries its own sidebar button.
                .toolbar(removing: .sidebarToggle)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: identity.topInset) }
                .background { MailColumnProbe(sizing: paneSizing, toolbarInset: toolbarInset, pane: .navigation, isPresented: identity.showsAssistant) }
                .padding(.trailing, Tokens.Layout.columnGutter)
                .overlay(alignment: .trailing) {
                    SplitDividerHandle()
                        .frame(width: Tokens.Layout.columnGutter)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { sidebarColumnWidth = $0 } }
                .navigationSplitViewColumnWidth(
                    min: Tokens.Layout.sidebarMinWidth + Tokens.Layout.columnGutter,
                    ideal: identity.showsAssistant ? AssistantSidebarLayout.navigationMinimum : Tokens.Layout.sidebarWidth + Tokens.Layout.columnGutter,
                    max: identity.showsAssistant ? AssistantSidebarLayout.navigationMinimum : Tokens.Layout.sidebarMaxWidth + Tokens.Layout.columnGutter
                )
        } content: {
            Group {
                if showsOutbox {
                    OutboxView(mailbox: mailbox, listFocused: $outboxFocused)
                } else {
                    ThreadListView(mailbox: mailbox)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: identity.topInset) }
            .background { MailColumnProbe(sizing: paneSizing, toolbarInset: toolbarInset, pane: .list, isPresented: identity.showsAssistant) }
            .onChange(of: mailbox.search.listFocusRequest) {
                outboxFocused = showsOutbox
            }
            .padding(.trailing, Tokens.Layout.columnGutter)
            .overlay(alignment: .trailing) {
                SplitDividerHandle()
                    .frame(width: Tokens.Layout.columnGutter)
            }
            .navigationSplitViewColumnWidth(
                min: Tokens.Layout.listMinWidth + Tokens.Layout.columnGutter,
                ideal: identity.showsAssistant ? AssistantSidebarLayout.listMinimum : Tokens.Layout.listWidth + Tokens.Layout.columnGutter,
                max: identity.showsAssistant ? AssistantSidebarLayout.listMinimum : nil
            )
        } detail: {
            MailDetailView(mailbox: mailbox)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: identity.topInset) }
                .navigationSplitViewColumnWidth(min: Tokens.Assistant.readerMinWidth, ideal: Tokens.Assistant.readerMinWidth)
                .background(Tokens.Surface.canvas)
        }
    }
}

private struct MailDetailView: View {
    let mailbox: MailboxModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let ids = mailbox.selectedThreadIDs
        if mailbox.selectedLabelID == MailboxModel.outboxID, !mailbox.search.isActive {
            TernEmptyState(
                title: "Outgoing Messages",
                systemImage: "tray.and.arrow.up",
                message: "Messages wait here until Gmail receives them. Double-click to open."
            )
        } else if !mailbox.listPreferences.conversations, mailbox.selectedMessageRows.count > 1 {
            TernEmptyState(title: "\(mailbox.selectedMessageRows.count) Messages Selected", systemImage: "square.stack",
                message: "Use the toolbar to organize your selection.")
        } else if ids.count == 1, let key = ids.first {
            let messageID = mailbox.listPreferences.conversations ? nil : mailbox.selectedMessageRows.first?.messageID
            ReaderSessionContainer(key: key, messageID: messageID, mailbox: mailbox, isActive: app.destination == .mail)
                .id(ReaderCacheLifecycle.shared.revision)
        } else if ids.count > 1 {
            TernEmptyState(
                title: "\(ids.count) Conversations Selected",
                systemImage: "square.stack",
                message: "Use the toolbar to organize your selection."
            )
        } else {
            TernEmptyState(
                title: mailbox.listPreferences.conversations ? "No Conversation Selected" : "No Message Selected",
                systemImage: "envelope.open"
            )
        }
    }
}
