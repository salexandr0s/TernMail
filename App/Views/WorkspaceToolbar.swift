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
    let accounts: AccountPreferencesModel?
    let section: WorkspaceSection
    let width: CGFloat
    let sidebar: SidebarToggle?
    let onSelect: (WorkspaceSection) -> Void
    let onNewMessage: () -> Void
    let onReply: (ReplyKind, SelectedMailQuote?) -> Void
    let isAssistantPresented: Bool
    let isAssistantAvailable: Bool
    let onToggleAssistant: () -> Void
    var isTasksPresented = false
    var onToggleTasks: () -> Void = {}

    private var showsProfile: Bool { section == .mail && accounts?.profiles.isEmpty == false }
    private var compactActions: Bool {
        width - (showsProfile ? Tokens.Layout.toolbarMenuWidth : 0) < Tokens.Layout.compactToolbarWidth
    }

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "workspace.sidebar", placement: .navigation) {
            Button(sidebar?.isVisible == true ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                sidebar?.toggle()
            }
            .help(sidebar?.isVisible == true ? "Hide Sidebar" : "Show Sidebar")
            .disabled(sidebar == nil)
            .popover(isPresented: Binding(
                get: { section == .attachments && library.isCompact && library.isPopoverPresented },
                set: { library.isPopoverPresented = $0 }
            ), arrowEdge: .top) {
                SidebarView(mailbox: mailbox)
                    .frame(width: Tokens.Layout.sidebarWidth, height: Tokens.Layout.windowMinHeight)
            }
        }
        .customizationBehavior(.disabled)
        WorkspaceSectionToolbar(section: section, onSelect: onSelect)
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

        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(id: "mail.profile", placement: .primaryAction) {
            if let accounts {
                ProfilePicker(model: accounts, isCompact: width < Tokens.Layout.wideToolbarWidth)
            }
        }
        .mailToolbarVisible(showsProfile)
        MailToolbar(mailbox: mailbox, reply: onReply, isCompact: compactActions,
            foldsReplies: width < Tokens.Layout.replyMenuFoldWidth, isVisible: section == .mail)
        // Mail's permanent spaces fall in the open area before other sections.
        CalendarToolbar(model: calendar).mailToolbarVisible(section == .calendar)
        AttachmentLibraryToolbar(state: library, isCompact: compactActions, isVisible: section == .attachments)
        WorkspaceSearchToolbar(mailbox: mailbox, calendar: calendar, libraryToolbar: library,
            section: section, isFolded: width < Tokens.Layout.searchFoldWidth)
        WorkspaceAssistantToolbar(isAssistantPresented: isAssistantPresented,
            onToggleAssistant: onToggleAssistant, isAssistantAvailable: isAssistantAvailable,
            isTasksPresented: isTasksPresented, onToggleTasks: onToggleTasks)
    }
}
