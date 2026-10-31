import AppKit
import MailStore
import MessageContent
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.selectedMailQuote) private var selectedQuote
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @AppStorage(MailWindowPreferences.hidesReaderKey) private var hidesReader = false
    @State private var isCompactWindow = false
    @State private var showsAssistant = false
    /// `Double`, because `@AppStorage` cannot store `CGFloat`.
    @AppStorage(AssistantSidebarLayout.widthKey) private var preferredAssistantWidth = Double(Tokens.Assistant.sidebarWidth)
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage("mailColumnVisibility") private var storedColumnVisibility = ""
    /// Set while the sidebar is hidden only because three columns don't fit.
    @State private var collapsedForWidth = false
    @State private var columnFit: ColumnFit?
    /// Kept with the window, so it follows the system setting for reopening
    /// windows after a quit.
    @SceneStorage("selectedMailbox") private var storedMailbox = ""
    @State private var previousColumnVisibility: NavigationSplitViewVisibility?
    @State private var paneSizing = AssistantMailPaneSizing()
    @State private var toolbarInset = ClippedSplitToolbarInset()
    @State private var libraryToolbar = AttachmentLibraryToolbarState()
    @FocusState private var outboxFocused: Bool
    let mailbox: MailboxModel
    var isActive = true
    var isCalendarAssistantPresented = false
    var onCalendarAssistantToggle: (() -> Void)?

    private var showsOutbox: Bool {
        mailbox.selectedLabelID == MailboxModel.outboxID && !mailbox.search.isActive
    }

    private var showsSidebar: Bool { columnVisibility == .all || (hidesReader && columnVisibility == .doubleColumn) }

    private var showsLibrary: Bool { mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID }
    /// Mail menu items act on this window while it shows mail, not the attachment library.
    private var focusedMailbox: MailboxModel? { isActive && !showsLibrary ? mailbox : nil }
    private var focusedLibraryToolbar: AttachmentLibraryToolbarState? { isActive && showsLibrary ? libraryToolbar : nil }

    /// View ▸ Show or Hide Sidebar acts on whichever split view is in front.
    private var sidebarToggle: SidebarToggle? {
        guard isActive else { return nil }
        if showsLibrary { return SidebarToggle(isVisible: libraryToolbar.showsSidebar, toggle: libraryToolbar.toggleSidebar) }
        return SidebarToggle(isVisible: showsSidebar, toggle: toggleSidebar)
    }

    private func toggleSidebar() {
        collapsedForWidth = false
        columnVisibility = showsSidebar ? (hidesReader ? .detailOnly : .doubleColumn) : .all
    }

    /// Whether the window is too narrow for the sidebar, list and reader
    /// minimums, and whether that matters: the assistant manages the sidebar
    /// itself, and the sidebar and list alone always fit.
    private struct ColumnFit: Equatable {
        let isNarrow: Bool
        let isManaged: Bool
    }

    /// Below the three column minimums the reader would run past the window's
    /// edge, so the sidebar steps aside until the window is wide enough again.
    /// A sidebar the user showed or hid stays as they left it.
    private func fitSidebar(_ fit: ColumnFit) {
        guard fit.isManaged else {
            // Without the reader, the sidebar and list always fit.
            if hidesReader, collapsedForWidth {
                collapsedForWidth = false
                columnVisibility = .all
            }
            return
        }
        if fit.isNarrow {
            guard columnVisibility == .all else { return }
            collapsedForWidth = true
            columnVisibility = .doubleColumn
        } else if collapsedForWidth {
            collapsedForWidth = false
            if columnVisibility == .doubleColumn { columnVisibility = .all }
        }
    }

    private var section: WorkspaceSection {
        guard isActive else { return .calendar }
        return showsLibrary ? .attachments : .mail
    }

    private func show(_ section: WorkspaceSection) {
        switch section {
        case .mail:
            app.destination = .mail
            if showsLibrary { mailbox.go(to: SystemLabel.inbox) }
        case .calendar:
            app.destination = .calendar
        case .attachments:
            app.destination = .mail
            mailbox.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)
        }
    }

    var body: some View {
        let contentTopInset = toolbarInset.top
        GeometryReader { geometry in
            let layout = AssistantSidebarLayout(availableWidth: geometry.size.width,
                preferredWidth: CGFloat(preferredAssistantWidth), isPresented: showsAssistant)
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
                updateNavigationVisibility(isNarrow: narrow && !hidesReader)
            }
            .onChange(of: layout.mailWidth, initial: true) { _, width in
                isCompactWindow = width < Tokens.Layout.compactToolbarWidth
                paneSizing.requestApply()
            }
            .onChange(of: ColumnFit(isNarrow: layout.mailWidth < AssistantSidebarLayout.threeColumnMinimum,
                                    isManaged: !showsAssistant && !hidesReader), initial: true) { _, fit in
                columnFit = fit
                fitSidebar(fit)
            }
            .onChange(of: geometry.size.height, initial: true) { _, _ in
                toolbarInset.refresh()
            }
        }
        .background {
            ShortcutMonitor(isEnabled: isActive && usesSingleKeys && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID, perform: perform)
        }
        .frame(minWidth: Tokens.Layout.windowMinWidth, minHeight: Tokens.Layout.windowMinHeight)
        .focusedSceneValue(\.mailboxModel, focusedMailbox)
        .focusedSceneValue(\.attachmentLibraryToolbar, focusedLibraryToolbar)
        .focusedSceneValue(\.sidebarToggle, sidebarToggle)
        .onAppear {
            mailbox.undoManager = undoManager
            if let stored = NavigationSplitViewVisibility(storageValue: storedColumnVisibility) {
                collapsedForWidth = false
                columnVisibility = stored
            }
            // The first layout may have run before the stored choice came back.
            if let columnFit { fitSidebar(columnFit) }
            if let stored = MailboxID(restorationValue: storedMailbox) { mailbox.restoreMailbox(stored) }
        }
        .onChange(of: mailbox.selectedMailbox) { _, box in storedMailbox = box?.restorationValue ?? "" }
        .onChange(of: columnVisibility) { _, visibility in
            // The assistant and a narrow window hide columns for a while; keep the user's own choice.
            if !showsAssistant, !collapsedForWidth { storedColumnVisibility = visibility.storageValue }
        }
        .modifier(AssistantAccessRefresh(mailbox: mailbox))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mailbox.syncNow()
        }
        .modifier(SignOutDialogs())
        .onChange(of: mailbox.draftToReopen) { _, id in
            guard let id else { return }
            mailbox.draftToReopen = nil
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
        .modifier(MainMailFeatures(mailbox: mailbox, libraryToolbar: libraryToolbar))
    }

    private func mailContent(topInset: CGFloat) -> some View {
        MailWorkspaceColumns(columnVisibility: $columnVisibility, showsReader: !hidesReader) {
            SidebarView(mailbox: mailbox)
                // AppKit asserts when the system toggle, or any item over the sidebar
                // column, meets a saved customizable toolbar or a second window, so
                // the content toolbar carries its own sidebar button.
                .toolbar(removing: .sidebarToggle)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: topInset) }
                .background { AssistantMailPaneProbe(sizing: paneSizing, toolbarInset: toolbarInset, pane: .navigation, isPresented: showsAssistant) }
                .padding(.trailing, Tokens.Layout.columnGutter)
                .overlay(alignment: .trailing) {
                    SplitDividerHandle()
                        .frame(width: Tokens.Layout.columnGutter)
                }
                .navigationSplitViewColumnWidth(
                    min: Tokens.Layout.sidebarMinWidth + Tokens.Layout.columnGutter,
                    ideal: showsAssistant ? AssistantSidebarLayout.navigationMinimum : Tokens.Layout.sidebarWidth + Tokens.Layout.columnGutter,
                    max: showsAssistant ? AssistantSidebarLayout.navigationMinimum : Tokens.Layout.sidebarMaxWidth + Tokens.Layout.columnGutter
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
            .background { AssistantMailPaneProbe(sizing: paneSizing, toolbarInset: toolbarInset, pane: .list, isPresented: showsAssistant) }
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
                ideal: showsAssistant ? AssistantSidebarLayout.listMinimum : Tokens.Layout.listWidth + Tokens.Layout.columnGutter,
                max: showsAssistant ? AssistantSidebarLayout.listMinimum : nil
            )
        } detail: {
            DetailView(mailbox: mailbox)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: topInset) }
                .navigationSplitViewColumnWidth(min: Tokens.Assistant.readerMinWidth, ideal: Tokens.Assistant.readerMinWidth)
                .background(Tokens.Surface.canvas)
        }
        .toolbar(id: MailWindowPreferences.toolbarID) {
            ToolbarItem(id: "workspace.sidebar", placement: .navigation) {
                Button(sidebarToggle?.isVisible == false ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left") {
                    sidebarToggle?.toggle()
                }
                .help(sidebarToggle?.isVisible == false ? "Show Sidebar" : "Hide Sidebar")
            }
            .customizationBehavior(.disabled)
            .mailToolbarVisible(sidebarToggle != nil)
            // Mail and Attachments switch sections from the sidebar's Library rows;
            // Calendar has no mail sidebar, so its toolbar offers the way back.
            WorkspaceSectionToolbar(section: section, onSelect: show)
                .mailToolbarVisible(!isActive && onCalendarAssistantToggle != nil)
            ToolbarItem(id: "mail.compose", placement: .navigation) {
                Button(action: newMessage) { Label("New Message", systemImage: "square.and.pencil") }
                    .help("New Message")
            }
            .mailToolbarVisible(isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID)
            ToolbarItem(id: "mail.profile", placement: .navigation) {
                if let preferences = app.accountPreferences { ProfilePicker(model: preferences) }
            }
            .mailToolbarVisible(isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID && app.accountPreferences != nil)
            MailToolbar(mailbox: mailbox, reply: reply, isCompact: isCompactWindow, isVisible: isActive && !showsLibrary)
            // After the mail items, so the mail toolbar's space stays out of these groups.
            CalendarToolbar(model: app.calendar)
                .mailToolbarVisible(!isActive && onCalendarAssistantToggle != nil)
            AttachmentLibraryToolbar(state: libraryToolbar).mailToolbarVisible(isActive && showsLibrary)
            WorkspaceSearchToolbar(
                mailbox: mailbox, calendar: app.calendar, libraryToolbar: libraryToolbar,
                section: section, isCompact: isCompactWindow
            )
            WorkspaceAssistantToolbar(
                isAssistantPresented: isActive ? showsAssistant : isCalendarAssistantPresented,
                onToggleAssistant: { if isActive { toggleAssistant() } else { onCalendarAssistantToggle?() } },
                isAssistantAvailable: !isActive || mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID
            )
            .mailToolbarVisible(isActive || onCalendarAssistantToggle != nil)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .navigationTitle(!isActive ? "Calendar"
            : mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID ? "Attachments" : mailbox.selectedLabelTitle)
        .navigationSubtitle(isActive && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID
            ? mailbox.selectedMailboxSubtitle : "")
        .modifier(MailNoticeOverlay(mailbox: mailbox))
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
        preferredAssistantWidth = Double(min(max(width, Tokens.Assistant.sidebarMinWidth), Tokens.Assistant.sidebarMaxWidth))
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
            if let key = mailbox.selectedThreadIDs.first, mailbox.selectedThreadIDs.count == 1,
               let quote = selectedQuote, quote.belongsTo(accountID: key.accountID, threadID: key.threadID,
                messageID: mailbox.listPreferences.conversations ? nil : mailbox.selectedMessageRows.first?.messageID) {
                guard let id = await mailbox.requestReply(kind, messageID: quote.messageID,
                    accountID: quote.accountID, selectedText: quote.text) else { return }
                openWindow(id: ComposeWindow.sceneID, value: id)
                return
            }
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
}

/// Keeps the assistant's account access current as the mailbox changes.
private struct AssistantAccessRefresh: ViewModifier {
    let mailbox: MailboxModel
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .task { await app.assistant.refreshConnection() }
            .onChange(of: app.assistant.connection.connectionRevision) { _, _ in app.assistant.refreshAccess() }
            .onChange(of: mailbox.accounts.map(\.account.id)) { _, _ in app.assistant.refreshAccess() }
            .onChange(of: app.accountsNeedingSignIn) { _, _ in app.assistant.refreshAccess() }
            .onChange(of: mailbox.selectedMailbox) { _, _ in app.assistant.refreshAccess() }
            .onChange(of: mailbox.selectedThreadIDs) { _, _ in app.assistant.refreshAccess() }
    }
}

/// The sign-out confirmations the Mailbox menu and account headers open.
private struct SignOutDialogs: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        @Bindable var app = app
        content
            .confirmationDialog("Sign out of Tern?", isPresented: $app.isConfirmingSignOut) {
                Button("Sign Out", role: .destructive) {
                    Task { await app.signOut() }
                }
            } message: {
                Text(app.signOutMessage)
            }
            .ternConfirm(
                "Sign out of \(app.accountToSignOut?.email ?? "this account")?",
                item: $app.accountToSignOut,
                actionTitle: "Sign Out",
                message: app.accountToSignOut.map { app.signOutMessage(for: $0) } ?? ""
            ) { account in
                Task { await app.signOut(of: account.id) }
            }
    }
}

private struct DetailView: View {
    let mailbox: MailboxModel
    @Environment(AppModel.self) private var app

    private struct ReaderIdentity: Hashable { let key: ThreadKey; let messageID: String? }

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
            ThreadView(key: key, mailbox: mailbox, selectedMessageID: messageID, isReaderActive: app.destination == .mail)
                .id(ReaderIdentity(key: key, messageID: messageID))
        } else if ids.count > 1 {
            TernEmptyState(
                title: "\(ids.count) Conversations Selected",
                systemImage: "square.stack",
                message: "Use the toolbar to organize your selection."
            )
        } else {
            TernEmptyState(
                title: "No Conversation Selected",
                systemImage: "envelope.open",
                message: "Start a new message with ⌘N."
            )
        }
    }
}
