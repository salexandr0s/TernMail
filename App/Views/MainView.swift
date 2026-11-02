import AppKit
import MailStore
import MessageContent
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.workspaceToolbarID) private var toolbarIdentifier
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @AppStorage(MailWindowPreferences.hidesReaderKey) private var hidesReader = false
    @State private var mailWidth: CGFloat = 0
    @State private var workspaceWidth = Tokens.Layout.windowWidth
    /// The sidebar hid because the window got narrower than the three
    /// columns' minimum widths, and comes back once the window is wide again.
    @State private var sidebarHiddenForWidth = false
    /// The sidebar column's last width while visible, gutter included.
    @State private var sidebarColumnWidth = Tokens.Layout.sidebarWidth + Tokens.Layout.columnGutter
    @State private var utilityPanel: WorkspacePanel?
    private var showsPanel: Bool { utilityPanel != nil }
    @State private var hostWindow: NSWindow?
    /// `Double`, because `@AppStorage` cannot store `CGFloat`.
    @AppStorage(AssistantSidebarLayout.widthKey) private var preferredAssistantWidth = Double(Tokens.Assistant.sidebarWidth)
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage("mailColumnVisibility") private var storedColumnVisibility = ""
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
    var calendarPanel: WorkspacePanel?
    var onCalendarPanelToggle: ((WorkspacePanel) -> Void)?
    var calendarSidebarState: CalendarSidebarState?

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
        guard isActive else { return calendarSidebarState?.sidebarToggle }
        if showsLibrary { return SidebarToggle(isVisible: libraryToolbar.showsSidebar, toggle: libraryToolbar.toggleSidebar) }
        return SidebarToggle(isVisible: showsSidebar, toggle: toggleSidebar)
    }

    private func toggleSidebar() {
        sidebarHiddenForWidth = false
        columnVisibility = showsSidebar ? (hidesReader ? .detailOnly : .doubleColumn) : .all
    }

    /// Below the three columns' minimum widths the split view clips the
    /// sidebar and the reader, so the sidebar steps aside until there's room.
    private func fitColumns(to width: CGFloat) {
        guard width > 0, !showsPanel, !hidesReader else { return }
        if width < AssistantSidebarLayout.threeColumnMinimum {
            guard columnVisibility == .all else { return }
            sidebarHiddenForWidth = true
            columnVisibility = .doubleColumn
        } else if sidebarHiddenForWidth, width >= widthToRestoreSidebar {
            sidebarHiddenForWidth = false
            if columnVisibility == .doubleColumn { columnVisibility = .all }
        }
    }

    /// AppKit widens the window to show the sidebar unless the window keeps
    /// its minimum width beside it, so a sidebar hidden for width waits for
    /// that much room rather than making the window jump.
    private var widthToRestoreSidebar: CGFloat {
        sidebarColumnWidth + Tokens.Border.hairline + Tokens.Layout.windowMinWidth
    }

    /// While the assistant shows, the window keeps room for the list and reader beside it.
    private var minimumWidth: CGFloat {
        showsPanel && !hidesReader ? AssistantSidebarLayout.windowMinimum : Tokens.Layout.windowMinWidth
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
                preferredWidth: CGFloat(preferredAssistantWidth), isPresented: showsPanel)
            HStack(spacing: 0) {
                // A split wider than the mail area runs under the assistant and
                // keeps its leading edge, the sidebar or the list, in view.
                mailContent(topInset: contentTopInset)
                    .frame(width: layout.mailWidth, alignment: .leading)
                    .clipped()
                if showsPanel {
                    Rectangle()
                        .fill(Tokens.Surface.border)
                        .frame(width: Tokens.Border.hairline)
                        .overlay {
                            AssistantSidebarResizeHandle(width: layout.sidebarWidth, onResize: resizeAssistant)
                                .frame(width: Tokens.Space.s3)
                                .accessibilityElement()
                                .accessibilityLabel(utilityPanel == .tasks ? "Tasks width" : "Assistant width")
                                .accessibilityValue("\(Int(layout.sidebarWidth)) points")
                                .accessibilityAdjustableAction { direction in
                                    resizeAssistant(layout.sidebarWidth + (direction == .increment ? Tokens.Space.s4 : -Tokens.Space.s4))
                                }
                        }
                    Group {
                        if utilityPanel == .tasks {
                            GoogleTasksSidebar(model: app.tasks, onClose: closePanel, isActive: isActive)
                        } else {
                            AssistantView(model: app.assistant, onOpenSource: app.openAssistantSource,
                                onExpand: { openAssistantWindow(fullScreen: true) },
                                onDetach: { openAssistantWindow(fullScreen: false) }, onClose: closePanel)
                        }
                    }
                    .frame(width: layout.sidebarWidth)
                    .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: layout.hidesMailboxNavigation, initial: true) { _, narrow in
                updateNavigationVisibility(isNarrow: narrow && !hidesReader)
            }
            .onChange(of: layout.mailWidth, initial: true) { _, width in
                mailWidth = width
                fitColumns(to: width)
                paneSizing.requestApply()
            }
            .onChange(of: geometry.size.height, initial: true) { _, _ in
                toolbarInset.refresh()
            }
        }
        .background {
            MailShortcutContext(isEnabled: isActive && usesSingleKeys && mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID,
                perform: perform)
        }
        .background { WindowReader { hostWindow = $0 } }
        .frame(minWidth: minimumWidth, minHeight: Tokens.Layout.windowMinHeight)
        .focusedSceneValue(\.mailboxModel, focusedMailbox)
        .focusedSceneValue(\.attachmentLibraryToolbar, focusedLibraryToolbar)
        .focusedSceneValue(\.sidebarToggle, sidebarToggle)
        .onAppear {
            mailbox.undoManager = undoManager
            if let stored = NavigationSplitViewVisibility(storageValue: storedColumnVisibility) {
                sidebarHiddenForWidth = false
                columnVisibility = stored
            }
            // The first layout may have run before the stored choice came back.
            fitColumns(to: mailWidth)
            if let stored = MailboxID(restorationValue: storedMailbox) { mailbox.restoreMailbox(stored) }
        }
        .onChange(of: mailbox.selectedMailbox) { _, box in storedMailbox = box?.restorationValue ?? "" }
        .onChange(of: columnVisibility) { _, visibility in
            // The assistant and a narrow window hide columns for a while; keep the user's own choice.
            if !showsPanel && !sidebarHiddenForWidth { storedColumnVisibility = visibility.storageValue }
        }
        .onChange(of: hidesReader) { _, _ in fitColumns(to: mailWidth) }
        .onChange(of: app.tasksSidebarRequest, initial: true) { _, request in
            if isActive, request != nil { presentPanel(.tasks); app.didShowTasks() }
        }
        .modifier(AssistantAccessRefresh(mailbox: mailbox))
        .modifier(SignOutDialogs())
        .onChange(of: mailbox.draftToReopen) { _, id in
            guard let id else { return }
            mailbox.draftToReopen = nil
            openWindow(id: ComposeWindow.sceneID, value: id)
        }
        .modifier(MainMailFeatures(mailbox: mailbox, libraryToolbar: libraryToolbar))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { workspaceWidth = $0 }
        .toolbar(id: toolbarIdentifier) {
            WorkspaceToolbar(mailbox: mailbox, calendar: app.calendar, library: libraryToolbar,
                accounts: app.accountPreferences, section: section, width: workspaceWidth, sidebar: sidebarToggle,
                onSelect: show, onNewMessage: newMessage, onReply: reply,
                isAssistantPresented: section == .attachments ? false : (isActive ? utilityPanel : calendarPanel) == .assistant,
                isAssistantAvailable: section != .attachments && (isActive || onCalendarPanelToggle != nil),
                onToggleAssistant: { if isActive { togglePanel(.assistant) } else { onCalendarPanelToggle?(.assistant) } },
                isTasksPresented: (isActive ? utilityPanel : calendarPanel) == .tasks,
                onToggleTasks: { if isActive { togglePanel(.tasks) } else { onCalendarPanelToggle?(.tasks) } })
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar(removing: workspaceWidth < Tokens.Layout.toolbarTitleFoldWidth ? .title : nil)
        .navigationTitle(section == .calendar ? "Calendar" : showsLibrary ? "Attachments" : mailbox.selectedLabelTitle)
        .navigationSubtitle(section == .mail ? mailbox.selectedMailboxSubtitle : "")
    }

    private func mailContent(topInset: CGFloat) -> some View {
        MailColumnsContent(mailbox: mailbox,
            identity: .init(columnVisibility: columnVisibility, showsReader: !hidesReader,
                showsAssistant: showsPanel, topInset: topInset, outboxFocused: outboxFocused),
            columnVisibility: $columnVisibility, sidebarColumnWidth: $sidebarColumnWidth,
            outboxFocused: $outboxFocused, paneSizing: paneSizing, toolbarInset: toolbarInset)
        .equatable()
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .modifier(MailNoticeOverlay(mailbox: mailbox))
    }

    private func togglePanel(_ panel: WorkspacePanel) {
        if utilityPanel == panel { closePanel() }
        else { presentPanel(panel) }
    }

    private func presentPanel(_ panel: WorkspacePanel) {
        if !showsPanel {
            paneSizing.beginPresentation()
            previousColumnVisibility = columnVisibility
            widenForAssistant()
        }
        utilityPanel = panel
    }

    /// AppKit widens a window to show a sidebar that doesn't fit, so opening
    /// the assistant widens a window too narrow for the list and reader beside
    /// it, keeping the window's right edge on its screen.
    private func widenForAssistant() {
        guard !hidesReader, let hostWindow, !hostWindow.styleMask.contains(.fullScreen) else { return }
        let screen = hostWindow.screen?.visibleFrame
        let width = min(AssistantSidebarLayout.windowMinimum, screen?.width ?? .greatestFiniteMagnitude)
        let content = hostWindow.contentRect(forFrameRect: hostWindow.frame)
        guard content.width < width else { return }
        var frame = hostWindow.frameRect(forContentRect: NSRect(origin: content.origin, size: NSSize(width: width, height: content.height)))
        if let screen, frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
        hostWindow.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func closePanel() {
        guard showsPanel else { return }
        utilityPanel = nil
        if let previousColumnVisibility { columnVisibility = previousColumnVisibility }
        previousColumnVisibility = nil
        paneSizing.endPresentation()
    }

    private func updateNavigationVisibility(isNarrow: Bool) {
        guard showsPanel, let previousColumnVisibility else { return }
        columnVisibility = isNarrow && previousColumnVisibility != .detailOnly ? .doubleColumn : previousColumnVisibility
    }

    private func resizeAssistant(_ width: CGFloat) {
        preferredAssistantWidth = Double(min(max(width, Tokens.Assistant.sidebarMinWidth), Tokens.Assistant.sidebarMaxWidth))
    }

    private func openAssistantWindow(fullScreen: Bool) {
        closePanel()
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
    private func perform(_ action: SingleKeyShortcuts.Action, selectedQuote: SelectedMailQuote?) -> Bool {
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
        case .reply: reply(.reply, quote: selectedQuote)
        case .replyAll: reply(.replyAll, quote: selectedQuote)
        case .forward: reply(.forward, quote: selectedQuote)
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

    private func reply(_ kind: ReplyKind, quote selectedQuote: SelectedMailQuote?) {
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
}

/// Keeps selected-text focus observation with the shortcut handler.
struct MailShortcutContext: View {
    @FocusedValue(\.selectedMailQuote) private var selectedQuote
    let isEnabled: Bool
    let perform: (SingleKeyShortcuts.Action, SelectedMailQuote?) -> Bool

    var body: some View {
        ShortcutMonitor(isEnabled: isEnabled) { action in
            perform(action, selectedQuote)
        }
    }
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
