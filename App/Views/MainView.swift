import AppKit
import MailStore
import MessageContent
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @State private var isCompactWindow = false
    @State private var showsAssistant = false
    @State private var preferredAssistantWidth = Tokens.Assistant.sidebarWidth
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var previousColumnVisibility: NavigationSplitViewVisibility?
    @State private var paneSizing = AssistantMailPaneSizing()
    @FocusState private var outboxFocused: Bool
    let mailbox: MailboxModel
    var isActive = true

    private var showsOutbox: Bool {
        mailbox.selectedLabelID == MailboxModel.outboxID && !mailbox.search.isActive
    }

    var body: some View {
        @Bindable var app = app
        let contentTopInset = paneSizing.contentTopInset
        GeometryReader { geometry in
            let layout = AssistantSidebarLayout(availableWidth: geometry.size.width,
                preferredWidth: preferredAssistantWidth, isPresented: showsAssistant)
            HStack(spacing: 0) {
                mailContent(topInset: contentTopInset)
                    .frame(width: layout.mailWidth)
                    .clipped()
                if showsAssistant {
                    Rectangle()
                        .fill(Tokens.Surface.border)
                        .frame(width: Tokens.Border.hairline)
                        .overlay {
                            AssistantSidebarResizeHandle(width: layout.sidebarWidth, onResize: resizeAssistant)
                                .frame(width: Tokens.Space.s3)
                                .accessibilityElement()
                                .accessibilityLabel("Assistant width")
                                .accessibilityValue("\(Int(layout.sidebarWidth)) points")
                                .accessibilityAdjustableAction { direction in
                                    resizeAssistant(layout.sidebarWidth + (direction == .increment ? Tokens.Space.s4 : -Tokens.Space.s4))
                                }
                        }
                    AssistantView(model: app.assistant, onOpenSource: app.openAssistantSource,
                        onExpand: { openAssistantWindow(fullScreen: true) },
                        onDetach: { openAssistantWindow(fullScreen: false) }, onClose: closeAssistant)
                        .frame(width: layout.sidebarWidth)
                        .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: layout.hidesMailboxNavigation, initial: true) { _, narrow in
                updateNavigationVisibility(isNarrow: narrow)
            }
            .onChange(of: layout.mailWidth, initial: true) { _, width in
                isCompactWindow = width < Tokens.Layout.compactToolbarWidth
                paneSizing.requestApply()
            }
            .onChange(of: geometry.size.height, initial: true) { _, _ in
                paneSizing.refreshWindowSafeArea()
            }
        }
        .background {
            ShortcutMonitor(isEnabled: isActive && usesSingleKeys && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID, perform: perform)
        }
        .frame(minWidth: Tokens.Layout.windowMinWidth, minHeight: Tokens.Layout.windowMinHeight)
        .focusedSceneValue(\.mailboxModel, isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID ? mailbox : nil)
        .onAppear { mailbox.undoManager = undoManager }
        .task { await app.assistant.refreshConnection() }
        .onChange(of: app.assistant.connection.connectionRevision) { _, _ in app.assistant.refreshAccess() }
        .onChange(of: mailbox.accounts.map(\.account.id)) { _, _ in app.assistant.refreshAccess() }
        .onChange(of: app.accountsNeedingSignIn) { _, _ in app.assistant.refreshAccess() }
        .onChange(of: mailbox.selectedMailbox) { _, _ in app.assistant.refreshAccess() }
        .onChange(of: mailbox.selectedThreadIDs) { _, _ in app.assistant.refreshAccess() }
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
        .modifier(AttachmentLibraryPresentation(mailbox: mailbox))
    }

    private func mailContent(topInset: CGFloat) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(mailbox: mailbox)
                .toolbar(removing: .sidebarToggle)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: topInset) }
                .background { AssistantMailPaneProbe(sizing: paneSizing, pane: .navigation, isPresented: showsAssistant) }
                .padding(.trailing, Tokens.Space.s3)
                .overlay(alignment: .trailing) {
                    SplitDividerHandle()
                        .frame(width: Tokens.Space.s3)
                }
                .navigationSplitViewColumnWidth(
                    min: Tokens.Layout.sidebarMinWidth + Tokens.Space.s3,
                    ideal: showsAssistant ? AssistantSidebarLayout.navigationMinimum : Tokens.Layout.sidebarWidth + Tokens.Space.s3,
                    max: showsAssistant ? AssistantSidebarLayout.navigationMinimum : Tokens.Layout.sidebarMaxWidth + Tokens.Space.s3
                )
        } content: {
            Group {
                if showsOutbox {
                    OutboxView(mailbox: mailbox, listFocused: $outboxFocused)
                } else {
                    ThreadListView(mailbox: mailbox)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: topInset) }
            .background { AssistantMailPaneProbe(sizing: paneSizing, pane: .list, isPresented: showsAssistant) }
            .onChange(of: mailbox.search.listFocusRequest) {
                outboxFocused = showsOutbox
            }
            .padding(.trailing, Tokens.Space.s3)
            .overlay(alignment: .trailing) {
                SplitDividerHandle()
                    .frame(width: Tokens.Space.s3)
            }
            .navigationSplitViewColumnWidth(
                min: Tokens.Layout.listMinWidth + Tokens.Space.s3,
                ideal: showsAssistant ? AssistantSidebarLayout.listMinimum : Tokens.Layout.listWidth + Tokens.Space.s3,
                max: showsAssistant ? AssistantSidebarLayout.listMinimum : nil
            )
            .toolbar {
                if isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID {
                    ToolbarItem(placement: .navigation) {
                        Button(columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                            columnVisibility = columnVisibility == .all ? .doubleColumn : .all
                        }
                        .help(columnVisibility == .all ? "Hide Sidebar" : "Show Sidebar")
                    }
                    ToolbarItem(placement: .navigation) {
                        Button(action: newMessage) {
                            Label("New Message", systemImage: "square.and.pencil")
                        }
                        .help("New Message")
                    }
                }
            }
        } detail: {
            DetailView(mailbox: mailbox)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: topInset) }
                .navigationSplitViewColumnWidth(min: Tokens.Assistant.readerMinWidth, ideal: Tokens.Assistant.readerMinWidth)
                .background(Tokens.Surface.canvas)
                .toolbar {
                    if isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID {
                        MailToolbar(mailbox: mailbox, reply: reply, isCompact: isCompactWindow)
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(!isActive ? "Calendar"
            : mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID ? "Attachments" : mailbox.selectedLabelTitle)
        .navigationSubtitle(isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID
            ? mailbox.selectedMailboxSubtitle : "")
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
                AssistantLauncher(isPresented: showsAssistant, onToggle: toggleAssistant)
            }
            .padding(Tokens.Space.s4)
            .ternAnimation(value: mailbox.notice)
            .ternAnimation(value: mailbox.sendNotice)
        }
    }

    private func toggleAssistant() {
        if showsAssistant { closeAssistant(); return }
        // Capture divider positions before narrowing or hiding a native column.
        paneSizing.beginPresentation()
        previousColumnVisibility = columnVisibility
        showsAssistant = true
    }

    private func closeAssistant() {
        guard showsAssistant else { return }
        showsAssistant = false
        if let previousColumnVisibility { columnVisibility = previousColumnVisibility }
        previousColumnVisibility = nil
        paneSizing.endPresentation()
    }

    private func updateNavigationVisibility(isNarrow: Bool) {
        guard showsAssistant, let previousColumnVisibility else { return }
        columnVisibility = isNarrow && previousColumnVisibility != .detailOnly ? .doubleColumn : previousColumnVisibility
        paneSizing.requestApply()
    }

    private func resizeAssistant(_ width: CGFloat) {
        preferredAssistantWidth = min(max(width, Tokens.Assistant.sidebarMinWidth), Tokens.Assistant.sidebarMaxWidth)
    }

    private func openAssistantWindow(fullScreen: Bool) {
        closeAssistant()
        AssistantWindow.open(using: openWindow, fullScreen: fullScreen)
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
        case .openConversation: return !showsOutbox && !hasSelection
        case .nextConversation, .previousConversation: return !showsOutbox
        case .archive: return mailbox.canArchive
        case .trash: return mailbox.canTrash
        case .toggleStar, .markRead, .markUnread, .editLabels, .moveTo: return hasSelection
        case .snooze: return mailbox.canSnooze
        case .undo: return undoManager?.canUndo == true
        case .reply, .replyAll, .forward: return mailbox.canReply
        case .search, .newMessage, .showShortcuts, .go:
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
            TernEmptyState(
                title: "Outgoing messages",
                systemImage: "tray.and.arrow.up",
                message: "Messages wait here until Gmail receives them. Double-click to open."
            )
        } else if ids.count == 1, let key = ids.first {
            ThreadView(key: key, mailbox: mailbox)
                .id(key)
        } else if ids.count > 1 {
            TernEmptyState(
                title: "\(ids.count) conversations selected",
                systemImage: "square.stack",
                message: "Use the toolbar to organize your selection."
            )
        } else {
            TernEmptyState(
                title: "Select a conversation",
                systemImage: "envelope.open",
                message: "Start a new message with ⌘N."
            )
        }
    }
}
