import Observation
import SwiftUI

/// Calendar sidebar presentation shared by one window's toolbar and content.
@MainActor @Observable
final class CalendarSidebarState {
    private(set) var isCompact = false
    private(set) var userShowsSidebar = true
    var isPopoverPresented = false
    var width = Tokens.Calendar.sidebarWidth

    var showsSidebar: Bool { !isCompact && userShowsSidebar }

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

    func updateCompact(_ compact: Bool) {
        isCompact = compact
        if !compact { isPopoverPresented = false }
    }
}
