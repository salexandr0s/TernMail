import Observation
import SwiftUI

/// Calendar sidebar presentation shared by one window's toolbar and content.
@MainActor @Observable
final class CalendarSidebarState {
    /// The calendar is too narrow for a sidebar beside its grid.
    private(set) var isNarrow = false
    /// The widest sidebar the window's toolbar has room beside.
    private(set) var toolbarRoom = CGFloat.infinity
    private(set) var userShowsSidebar = true
    var isPopoverPresented = false
    var width = Tokens.Calendar.sidebarWidth

    /// A compact sidebar opens as a popover from its toolbar button.
    var isCompact: Bool { isNarrow || width > toolbarRoom }
    var showsSidebar: Bool { !isCompact && userShowsSidebar }
    /// A drag stops where the toolbar's controls would run out of room.
    var maximumWidth: CGFloat { min(Tokens.Layout.sidebarMaxWidth, max(Tokens.Layout.sidebarWidth, toolbarRoom)) }

    var sidebarToggle: SidebarToggle {
        SidebarToggle(isVisible: isCompact ? isPopoverPresented : showsSidebar, toggle: toggle)
    }

    func toggle() {
        if isCompact {
            isPopoverPresented.toggle()
        } else {
            userShowsSidebar.toggle()
        }
    }

    func updateNarrow(_ narrow: Bool) {
        isNarrow = narrow
        if !isCompact { isPopoverPresented = false }
    }

    func updateToolbarRoom(_ room: CGFloat) {
        toolbarRoom = room
        if !isCompact { isPopoverPresented = false }
    }
}
