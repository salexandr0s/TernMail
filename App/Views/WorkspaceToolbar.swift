import MessageContent
import SwiftUI

extension EnvironmentValues {
    /// Hosted windows can keep native toolbar state separate from the app's window.
    @Entry var workspaceToolbarID = MailWindowPreferences.toolbarID
}

/// One toolbar layout for every section. Navigation stays on the left and
/// Search and Assistant stay on the right; only the middle actions change.
struct WorkspaceToolbar: CustomizableToolbarContent {
    let mailbox: MailboxModel
    let calendar: CalendarModel
    let library: AttachmentLibraryToolbarState
    let followUps: FollowUpsModel
    let today: TodayModel
    let accounts: AccountPreferencesModel?
    /// The section whose items show. It follows `frontSection` a moment later,
    /// because swapping one section's items for another's is slow.
    let section: WorkspaceSection
    /// The section in front. The section picker shows it at once.
    let frontSection: WorkspaceSection
    let layout: WorkspaceToolbarLayout
    let sidebar: SidebarToggle?
    let onSelect: (WorkspaceSection) -> Void
    let onNewMessage: () -> Void
    let onReply: (ReplyKind, SelectedMailQuote?) -> Void
    let isAssistantPresented: Bool
    let isAssistantAvailable: Bool
    let onToggleAssistant: () -> Void
    var isTasksPresented = false
    var onToggleTasks: () -> Void = {}
    var isCalendarUtilityCompact = false

    private var showsProfile: Bool {
        (section == .mail || section == .followUps || section == .today) && accounts?.profiles.isEmpty == false
            && !layout.foldsProfile
    }

    var body: some CustomizableToolbarContent {
        navigation
        WorkspaceSectionToolbar(section: frontSection, onSelect: onSelect)
        // Retain the existing identifier for saved toolbar configurations.
        ToolbarItem(id: "mail.compose", placement: .navigation) {
            Button {
                if section == .calendar { calendar.beginNew(on: calendar.date) }
                else { onNewMessage() }
            } label: {
                Label(section == .calendar ? "New Event" : "New Message",
                    systemImage: section == .calendar ? "plus" : "square.and.pencil")
            }
            .help(section == .calendar ? "New Event (\(ShortcutCatalog.newEvent.label))"
                : "New Message (\(ShortcutCatalog.newMessage.label))")
            .disabled(section == .calendar && !calendar.calendars.contains(where: \.canWrite))
        }
        .customizationBehavior(.disabled)
        .mailToolbarVisible(!isCalendarUtilityCompact && section != .followUps && section != .today)

        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(id: "mail.profile", placement: .primaryAction) {
            if let accounts {
                ProfilePicker(model: accounts, isCompact: layout.compactProfile)
            }
        }
        .mailToolbarVisible(showsProfile)
        MailToolbar(mailbox: mailbox, reply: onReply, isCompact: layout.compactActions,
            foldsReplies: layout.foldsReplies, foldedProfiles: layout.foldsProfile ? accounts : nil,
            isVisible: section == .mail)
        // Mail's permanent spaces fall in the open area before other sections.
        CalendarToolbar(model: calendar, isCompact: layout.compactActions, foldsToday: layout.foldsCalendarToday,
            foldsNavigation: layout.foldsCalendarNavigation,
            isVisible: section == .calendar && !isCalendarUtilityCompact)
        AttachmentLibraryToolbar(state: library, isCompact: layout.compactActions, isVisible: section == .attachments)
        WorkspaceSearchToolbar(mailbox: mailbox, calendar: calendar, libraryToolbar: library, followUps: followUps, today: today,
            section: section, isFolded: layout.foldsSearch)
            .mailToolbarVisible(!isCalendarUtilityCompact)
        WorkspaceAssistantToolbar(isAssistantPresented: isAssistantPresented,
            onToggleAssistant: onToggleAssistant, isAssistantAvailable: isAssistantAvailable,
            isTasksPresented: isTasksPresented, onToggleTasks: onToggleTasks)
    }

    private var navigation: some CustomizableToolbarContent {
        // Sidebar and Refresh are one item. AppKit draws neighboring items in one
        // glass platter, and after a section switch it could leave that platter
        // between points while the items stayed on them. Their sizes then changed
        // on every layout pass until AppKit stopped the app.
        ToolbarItem(id: "workspace.refresh", placement: .navigation) {
            HStack(spacing: 0) {
                if !isCalendarUtilityCompact && section != .followUps && section != .today {
                    sidebarButton
                }
                WorkspaceRefreshButton(mailbox: mailbox, calendar: calendar, library: library,
                    followUps: followUps, today: today, section: section)
            }
        }
        .customizationBehavior(.disabled)
    }

    private var sidebarButton: some View {
        Button(sidebar?.isVisible == true ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
            sidebar?.toggle()
        }
        .help(sidebar?.isVisible == true ? "Hide Sidebar" : "Show Sidebar")
        .disabled(sidebar == nil)
        .accessibilityIdentifier("workspace.sidebarButton")
        .popover(isPresented: Binding(
            get: { section == .attachments && library.isCompact && library.isPopoverPresented },
            set: { library.isPopoverPresented = $0 }
        ), arrowEdge: .top) {
            SidebarView(mailbox: mailbox)
                .frame(width: Tokens.Layout.sidebarWidth, height: Tokens.Layout.windowMinHeight)
        }
    }
}

/// Observe sync activity inside the control so it doesn't rebuild the toolbar.
private struct WorkspaceRefreshButton: View {
    let mailbox: MailboxModel
    let calendar: CalendarModel
    let library: AttachmentLibraryToolbarState
    let followUps: FollowUpsModel
    let today: TodayModel
    let section: WorkspaceSection

    private var isRefreshing: Bool {
        if section == .calendar { return calendar.isLoading }
        if section == .followUps { return followUps.isLoading }
        if section == .today { return today.isLoading }
        return (section == .attachments && library.isRefreshing) || mailbox.accounts.contains { $0.syncStatus == .syncing }
    }

    private var help: String {
        if isRefreshing { return "Refreshing \(section.title.lowercased())…" }
        switch section {
        case .mail: return "Refresh mail (\(ShortcutCatalog.checkForNewMail.label))"
        case .calendar: return "Refresh calendars"
        case .attachments: return "Refresh attachments"
        case .followUps: return "Refresh follow-ups"
        case .today: return "Refresh Today"
        }
    }

    var body: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            if section == .calendar { Task { await calendar.refresh() } }
            else if section == .followUps { Task { await followUps.refresh() } }
            else if section == .today { Task { await today.refresh() } }
            else if section == .attachments { library.refreshRequest += 1 }
            else { mailbox.syncNow() }
        }
        .help(help)
        .disabled(isRefreshing || (section == .attachments && library.isWorking))
        .accessibilityValue(isRefreshing ? "Refreshing" : "")
        .accessibilityIdentifier("workspace.refreshButton")
    }
}
