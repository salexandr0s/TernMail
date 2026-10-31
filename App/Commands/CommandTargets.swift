import SwiftUI

/// What the open reader can do for the menu bar. The reader publishes this
/// as a focused scene value while it is on screen.
struct ReaderActions {
    let canExpand: Bool
    let canCollapse: Bool
    let canPrint: Bool
    let expandAll: @MainActor () -> Void
    let collapseAll: @MainActor () -> Void
    let print: @MainActor (_ asPDF: Bool) -> Void
}

/// Calendar panels and sheets the menu bar opens. The calendar publishes
/// this while it is the main window's active destination.
struct CalendarActions {
    let showActivity: @MainActor () -> Void
    /// Opens Settings on the Calendar pane.
    let showManagement: @MainActor () -> Void
    let importEvents: @MainActor () -> Void
    let exportEvents: @MainActor () -> Void
    let exportCalendar: @MainActor (CalendarDisplayCalendar) -> Void
    let goToDate: @MainActor () -> Void
    let find: @MainActor () -> Void
    let print: @MainActor () -> Void
}

/// The sidebar of the split view in front, for View ▸ Show or Hide Sidebar.
struct SidebarToggle {
    let isVisible: Bool
    let toggle: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var sidebarToggle: SidebarToggle?
    @Entry var readerActions: ReaderActions?
    @Entry var calendarModel: CalendarModel?
    @Entry var calendarActions: CalendarActions?
    @Entry var assistantModel: AssistantModel?
    @Entry var attachmentLibraryToolbar: AttachmentLibraryToolbarState?
}
