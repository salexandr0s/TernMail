import AppKit
import MailStore
import MessageContent
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.workspaceToolbarID) private var toolbarIdentifier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @AppStorage(MailWindowPreferences.hidesReaderKey) private var hidesReader = false
    @State private var mailWidth: CGFloat = 0
    @State private var measuredWidth = Tokens.Layout.windowWidth
    /// The sidebar hid because the window got too narrow for the columns'
    /// minimum widths or for the toolbar beside it, and comes back once the
    /// window is wide again.
    @State private var sidebarHiddenForWidth = false
    /// The sidebar column's last width while visible, gutter included.
    @State private var sidebarColumnWidth = Tokens.Layout.sidebarWidth + Tokens.Layout.columnGutter
    @State private var utilityPanel: WorkspacePanel?
    private var showsPanel: Bool { utilityPanel != nil }
    @State private var hostWindow: NSWindow?
    @State private var toolbarDisplayMode = ToolbarDisplayMode()
    /// `Double`, because `@AppStorage` cannot store `CGFloat`.
    @AppStorage(AssistantSidebarLayout.widthKey) private var preferredAssistantWidth = Double(Tokens.Assistant.sidebarWidth)
    /// The panel's width while its divider is dragged. Saving a width writes
    /// it to disk and wakes every window that reads it, so a drag saves once,
    /// when it ends.
    @State private var draggedAssistantWidth: CGFloat?
    /// The window is growing to make room for the panel. Until it has, the
    /// wider minimum stays off, so the window grows smoothly and doesn't jump.
    @State private var isWideningWindow = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage("mailColumnVisibility") private var storedColumnVisibility = ""
    /// Kept with the window, so it follows the system setting for reopening
    /// windows after a quit.
    @SceneStorage("selectedMailbox") private var storedMailbox = ""
    @SceneStorage("showsAttachmentLibrary") private var storedLibrary = false
    @State private var previousColumnVisibility: NavigationSplitViewVisibility?
    @State private var paneSizing = AssistantMailPaneSizing()
    @State private var toolbarInset = ClippedSplitToolbarInset()
    @State private var libraryToolbar = AttachmentLibraryToolbarState()
    @FocusState private var outboxFocused: Bool
    /// The section whose items the toolbar shows. It takes a new `section`
    /// `Tokens.Motion.toolbarFollowDelay` after the content does. Hiding one
    /// section's items and showing another's costs AppKit about twice the
    /// main-thread time of the content change, and done in the same pass it
    /// held the new section off the screen that long. The section picker does
    /// not wait: it reads `section`.
    @State private var toolbarSection = WorkspaceSection.mail
    /// The toolbar shows Mail or the attachment library, whose panels this view owns.
    private var toolbarShowsMail: Bool { toolbarSection == .mail || toolbarSection == .attachments }
    let mailbox: MailboxModel
    var isActive = true
    /// The window's content width. While another section shows, the retained
    /// mail view can be laid out wider than the window.
    var windowWidth: CGFloat?
    var calendarPanel: WorkspacePanel?
    var onCalendarPanelToggle: ((WorkspacePanel) -> Void)?
    var calendarSidebarState: CalendarSidebarState?
    var isCalendarUtilityCompact = false

    private var showsOutbox: Bool {
        mailbox.selectedLabelID == MailboxModel.outboxID && !mailbox.search.isActive
    }

    private var showsSidebar: Bool { columnVisibility == .all || (hidesReader && columnVisibility == .doubleColumn) }

    private var showsLibrary: Bool { mailbox.showsAttachmentLibrary }
    /// Mail menu items act on this window while it shows mail, not the attachment library.
    private var focusedMailbox: MailboxModel? { isActive && !showsLibrary ? mailbox : nil }
    private var focusedLibraryToolbar: AttachmentLibraryToolbarState? { isActive && showsLibrary ? libraryToolbar : nil }

    /// View ▸ Show or Hide Sidebar acts on the split view of the section the toolbar shows.
    private var sidebarToggle: SidebarToggle? {
        switch toolbarSection {
        case .followUps, .today: nil
        case .calendar: isCalendarUtilityCompact ? nil : calendarSidebarState?.sidebarToggle
        case .attachments: libraryToolbar.sidebarToggle
        case .mail: SidebarToggle(isVisible: showsSidebar, toggle: toggleSidebar)
        }
    }

    private func toggleSidebar() {
        sidebarHiddenForWidth = false
        withAnimation(reduceMotion ? nil : Tokens.Motion.standard(duration: Tokens.Motion.slow)) {
            columnVisibility = showsSidebar ? (hidesReader ? .detailOnly : .doubleColumn) : .all
        }
    }

    /// Below the three columns' minimum widths the split view clips the
    /// sidebar and the reader, and in a window too narrow for the toolbar
    /// beside the sidebar AppKit moves Tasks and Assistant into the overflow
    /// menu. The sidebar steps aside until there's room for both.
    private func fitColumns(to width: CGFloat) {
        guard width > 0 else { return }
        // The assistant hides the sidebar itself while the reader shows.
        guard !showsPanel || hidesReader else { return }
        let crowdsColumns = !hidesReader && width < AssistantSidebarLayout.threeColumnMinimum
        let crowdsToolbar = sidebarColumnWidth > toolbarSidebarRoom
        if crowdsColumns || crowdsToolbar {
            guard showsSidebar else { return }
            sidebarHiddenForWidth = true
            columnVisibility = hidesReader ? .detailOnly : .doubleColumn
        } else if sidebarHiddenForWidth, width >= widthToRestoreSidebar {
            sidebarHiddenForWidth = false
            if !showsSidebar { columnVisibility = .all }
        }
    }

    /// A layout pass that runs before the window has its size reports a width
    /// below the window's minimum. Folding for it would hide every sidebar and
    /// open them again once the real width arrives.
    private var workspaceWidth: CGFloat {
        let width = windowWidth ?? measuredWidth
        return width >= Tokens.Layout.windowMinWidth ? width : Tokens.Layout.windowWidth
    }

    /// The profile picker's name in the toolbar, or nil while there are no profiles.
    private var profileNameWidth: CGFloat? { app.accountPreferences.flatMap(ProfilePicker.nameWidth) }

    private var toolbarSidebarRoom: CGFloat {
        WorkspaceToolbarLayout.sidebarRoom(for: .mail, width: workspaceWidth, hasProfiles: profileNameWidth != nil,
            labels: toolbarDisplayMode.showsLabels)
    }

    private var toolbarLayout: WorkspaceToolbarLayout {
        let calendar = isCalendarUtilityCompact ? nil : calendarSidebarState
        return WorkspaceToolbarLayout(section: toolbarSection, width: workspaceWidth, sidebars: .init(
            mail: showsSidebar ? sidebarColumnWidth : 0,
            calendar: calendar?.showsSidebar == true ? calendar?.width ?? 0 : 0,
            attachments: libraryToolbar.showsSidebar ? libraryToolbar.sidebarWidth : 0),
            profileNameWidth: profileNameWidth, labels: toolbarDisplayMode.showsLabels)
    }

    /// Every section's sidebar gives way to the toolbar at the same point in its folding.
    private func fitSidebars(to width: CGFloat) {
        let labels = toolbarDisplayMode.showsLabels
        calendarSidebarState?.updateToolbarRoom(
            WorkspaceToolbarLayout.sidebarRoom(for: .calendar, width: width, labels: labels))
        libraryToolbar.updateToolbarRoom(
            WorkspaceToolbarLayout.sidebarRoom(for: .attachments, width: width, labels: labels))
        fitColumns(to: mailWidth)
    }

    /// AppKit widens the window to show the sidebar unless the window keeps
    /// its minimum width beside it, so a sidebar hidden for width waits for
    /// that much room rather than making the window jump.
    private var widthToRestoreSidebar: CGFloat {
        sidebarColumnWidth + Tokens.Border.hairline + Tokens.Layout.windowMinWidth
    }

    /// While the assistant shows, the window keeps room for the list and reader beside it.
    private var minimumWidth: CGFloat {
        showsPanel && !hidesReader && !isWideningWindow ? AssistantSidebarLayout.windowMinimum : Tokens.Layout.windowMinWidth
    }

    /// The section whose content shows.
    private var section: WorkspaceSection {
        if app.destination == .today { return .today }
        if app.destination == .followUps { return .followUps }
        guard isActive else { return .calendar }
        return showsLibrary ? .attachments : .mail
    }

    private func show(_ section: WorkspaceSection) {
        switch section {
        case .mail:
            app.destination = .mail
            mailbox.leaveAttachmentLibrary()
        case .calendar:
            app.destination = .calendar
        case .attachments:
            app.destination = .mail
            mailbox.showAttachmentLibrary()
        case .followUps:
            app.destination = .followUps
        case .today:
            app.destination = .today
        }
    }

    private var workspaceLayout: some View {
        // Snapshot Mail before the new destination changes native column constraints.
        let _ = paneSizing.setToolbarSidebarWidth(toolbarSidebarWidth)
        let contentTopInset = toolbarInset.top
        return GeometryReader { geometry in
            let layout = AssistantSidebarLayout(availableWidth: geometry.size.width,
                preferredWidth: draggedAssistantWidth ?? CGFloat(preferredAssistantWidth), isPresented: showsPanel)
            // The mail columns take their new width in one pass and the panel
            // slides over them. Animating the width would lay the list and the
            // reader out again on every frame. A split wider than the mail area
            // runs under the panel and keeps its leading edge, the sidebar or
            // the list, in view.
            mailContent(topInset: contentTopInset)
                .frame(width: layout.mailWidth, alignment: .leading)
                .clipped()
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .overlay(alignment: .trailing) {
                    ZStack(alignment: .trailing) {
                        if showsPanel {
                            utilityPanelColumn(width: layout.sidebarWidth)
                                .ternTransition(.panel(edge: .trailing))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .clipped()
                    .ternAnimation(value: showsPanel, duration: Tokens.Motion.slow)
                    .allowsHitTesting(showsPanel && isActive)
                    .accessibilityHidden(!showsPanel || !isActive)
                }
                .clipped()
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
    }

    /// The divider and the Tasks or Assistant panel beside the mail columns.
    private func utilityPanelColumn(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.Surface.border)
                .frame(width: Tokens.Border.hairline)
                .overlay {
                    AssistantSidebarResizeHandle(width: width, onResize: resizeAssistant, onEnd: saveAssistantWidth)
                        .frame(width: Tokens.Space.s3)
                        .accessibilityElement()
                        .accessibilityLabel(utilityPanel == .tasks ? "Tasks width" : "Assistant width")
                        .accessibilityValue("\(Int(width)) points")
                        .accessibilityAdjustableAction { direction in
                            resizeAssistant(width + (direction == .increment ? Tokens.Space.s4 : -Tokens.Space.s4))
                            saveAssistantWidth()
                        }
                }
            ZStack {
                if utilityPanel == .tasks {
                    GoogleTasksSidebar(model: app.tasks, onClose: closePanel, isActive: isActive)
                        .ternTransition(.fade)
                } else {
                    AssistantView(model: app.assistant, onOpenSource: app.openAssistantSource,
                        onExpand: { openAssistantWindow(fullScreen: true) },
                        onDetach: { openAssistantWindow(fullScreen: false) }, onClose: closePanel)
                        .ternTransition(.fade)
                }
            }
            .ternAnimation(value: utilityPanel, duration: Tokens.Motion.fast)
            .frame(width: width)
            .clipped()
        }
    }

    private var workspaceScene: some View {
        workspaceLayout
        .background {
            MailShortcutContext(isEnabled: isActive && usesSingleKeys && !showsLibrary, perform: perform)
        }
        .background {
            WindowReader { window in
                window.titlebarSeparatorStyle = .line
                hostWindow = window
                toolbarDisplayMode.follow(window)
            }
        }
        .frame(minWidth: minimumWidth, minHeight: Tokens.Layout.windowMinHeight)
        .focusedSceneValue(\.mailboxModel, focusedMailbox)
        .focusedSceneValue(\.attachmentLibraryToolbar, focusedLibraryToolbar)
        .focusedSceneValue(\.followUpsModel,
            app.destination == .followUps && !isCalendarUtilityCompact ? app.followUps : nil)
        .focusedSceneValue(\.todayModel,
            app.destination == .today && !isCalendarUtilityCompact ? app.today : nil)
        .focusedSceneValue(\.sidebarToggle, sidebarToggle)
        .focusedValue(\.calendarWorkspaceHasFocus, app.destination == .calendar)
    }

    private var workspaceLifecycle: some View {
        workspaceScene
        .onAppear {
            mailbox.undoManager = undoManager
            if let stored = NavigationSplitViewVisibility(storageValue: storedColumnVisibility) {
                sidebarHiddenForWidth = false
                columnVisibility = stored
            }
            // The first layout may have run before the stored choice came back.
            fitColumns(to: mailWidth)
            mailbox.restoreMailbox(MailboxID(restorationValue: storedMailbox), showingAttachmentLibrary: storedLibrary)
        }
        .onChange(of: mailbox.selectedMailbox) { _, box in storedMailbox = box?.restorationValue ?? "" }
        .onChange(of: showsLibrary) { _, shows in storedLibrary = shows }
        .onChange(of: columnVisibility) { _, visibility in
            // The assistant and a narrow window hide columns for a while; keep the user's own choice.
            if !showsPanel && !sidebarHiddenForWidth { storedColumnVisibility = visibility.storageValue }
        }
        .onChange(of: hidesReader) { _, _ in fitColumns(to: mailWidth) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
            // A native resize can bypass SwiftUI's minimum frame. Keep the
            // reader beside an open panel without starting another animation.
            guard isActive, showsPanel, !isWideningWindow,
                  let window = notification.object as? NSWindow, window === hostWindow else { return }
            widenForAssistant(animated: false)
        }
        .onChange(of: isActive) { _, active in
            if active, showsPanel { widenForAssistant(animated: false) }
        }
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
    }

    var body: some View {
        let layout = toolbarLayout
        return workspaceLifecycle
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .onChange(of: workspaceWidth, initial: true) { _, width in fitSidebars(to: width) }
        .onChange(of: toolbarDisplayMode.showsLabels) { _, _ in fitSidebars(to: workspaceWidth) }
        .onChange(of: profileNameWidth == nil) { _, _ in fitColumns(to: mailWidth) }
        // A window opens with its section's toolbar; later changes follow the content.
        .onAppear { toolbarSection = section }
        // Mail's own column widths go back before its first frame.
        .onChange(of: toolbarSidebarWidth == nil) { _, isMail in
            if isMail { paneSizing.restoreToolbarPositionsEarly() }
        }
        .task(id: section) {
            guard toolbarSection != section else { return }
            do { try await Task.sleep(for: Tokens.Motion.toolbarFollowDelay) } catch { return }
            toolbarSection = section
        }
        #if TERN_TEST_SUPPORT || TERN_PERFORMANCE
        .onChange(of: [section, toolbarSection], initial: true) { _, sections in
            PerformanceToolbar.content = sections[0]
            PerformanceToolbar.toolbar = sections[1]
        }
        #endif
        .toolbar(id: toolbarIdentifier) {
            // The buttons act on the content in front, so their actions read `isActive`
            // while what they show follows the toolbar's section.
            WorkspaceToolbar(mailbox: mailbox, calendar: app.calendar, library: libraryToolbar,
                followUps: app.followUps, today: app.today,
                accounts: app.accountPreferences, section: toolbarSection, frontSection: section,
                layout: layout, sidebar: sidebarToggle,
                onSelect: show, onNewMessage: newMessage, onReply: reply,
                isAssistantPresented: toolbarSection == .attachments ? false
                    : (toolbarShowsMail ? utilityPanel : calendarPanel) == .assistant,
                isAssistantAvailable: toolbarSection != .attachments && (toolbarShowsMail || onCalendarPanelToggle != nil),
                onToggleAssistant: { if isActive { togglePanel(.assistant) } else { onCalendarPanelToggle?(.assistant) } },
                isTasksPresented: (toolbarShowsMail ? utilityPanel : calendarPanel) == .tasks,
                onToggleTasks: { if isActive { togglePanel(.tasks) } else { onCalendarPanelToggle?(.tasks) } },
                isCalendarUtilityCompact: !toolbarShowsMail && isCalendarUtilityCompact)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar(removing: layout.showsTitle ? nil : .title)
        .navigationTitle(toolbarSection == .mail ? mailbox.selectedLabelTitle : toolbarSection.title)
        .navigationSubtitle(toolbarSection == .mail ? mailbox.selectedMailboxSubtitle : "")
    }

    /// The retained Mail split owns the shared toolbar. Each visible destination
    /// supplies its sidebar geometry without changing Mail's saved layout.
    private var toolbarSidebarWidth: CGFloat? {
        // Mail's columns take their own widths back with Mail, ahead of the toolbar.
        if section == .mail { return nil }
        switch toolbarSection {
        // Mail's columns, now hidden, keep their widths until the toolbar follows.
        case .mail: return nil
        case .followUps, .today: return 0
        case .calendar: return isCalendarUtilityCompact ? 0 : calendarSidebarState.map { $0.showsSidebar ? $0.width : 0 }
        case .attachments: return libraryToolbar.showsSidebar ? libraryToolbar.sidebarWidth : 0
        }
    }

    private var toolbarColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            if let width = toolbarSidebarWidth {
                return width > 0 ? .all : (hidesReader ? .detailOnly : .doubleColumn)
            }
            return columnVisibility
        } set: { visibility in
            if toolbarSidebarWidth == nil { columnVisibility = visibility }
        }
    }

    private func mailContent(topInset: CGFloat) -> some View {
        MailColumnsContent(mailbox: mailbox,
            identity: .init(columnVisibility: toolbarColumnVisibility.wrappedValue, showsReader: !hidesReader,
                showsAssistant: showsPanel, topInset: topInset, outboxFocused: outboxFocused,
                toolbarSidebarWidth: toolbarSidebarWidth),
            columnVisibility: toolbarColumnVisibility, sidebarColumnWidth: $sidebarColumnWidth,
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
    private func widenForAssistant(animated: Bool = true) {
        guard !hidesReader, let hostWindow, !hostWindow.styleMask.contains(.fullScreen) else { return }
        let screen = hostWindow.screen?.visibleFrame
        let width = min(AssistantSidebarLayout.windowMinimum, screen?.width ?? .greatestFiniteMagnitude)
        let content = hostWindow.contentRect(forFrameRect: hostWindow.frame)
        guard content.width < width else { return }
        var frame = hostWindow.frameRect(forContentRect: NSRect(origin: content.origin, size: NSSize(width: width, height: content.height)))
        if let screen, frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            hostWindow.setFrame(frame, display: true)
            return
        }
        // An animated `setFrame` holds the main thread until the window has
        // its new frame. The animator returns at once, so the panel slides in
        // while the window grows.
        isWideningWindow = true
        Task {
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = Tokens.Motion.slow
                hostWindow.animator().setFrame(frame, display: true)
            }
            isWideningWindow = false
        }
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
        draggedAssistantWidth = AssistantSidebarLayout.clampedWidth(width)
    }

    private func saveAssistantWidth() {
        guard let width = draggedAssistantWidth else { return }
        preferredAssistantWidth = Double(width)
        draggedAssistantWidth = nil
    }

    private func openAssistantWindow(fullScreen: Bool) {
        closePanel()
        AssistantWindow.open(using: openWindow, fullScreen: fullScreen)
    }

    private func newMessage() {
        ComposeWindow.open(with: openWindow) { [mailbox] in await mailbox.startCompose(.newMessage) }
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
        ComposeWindow.open(with: openWindow) { [mailbox] in await mailbox.startReply(kind, quote: selectedQuote) }
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
            .onChange(of: app.assistant.connectionRevision) { _, _ in app.assistant.refreshAccess() }
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
