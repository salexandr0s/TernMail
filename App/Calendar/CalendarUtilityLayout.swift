import SwiftUI

extension FocusedValues {
    @Entry var calendarWorkspaceHasFocus: Bool?
}

/// Use an adjacent utility only while both panes fit. Resizing never rewrites
/// the user's preferred width or changes the utility view's identity.
struct CalendarUtilityLayout {
    let calendarWidth: CGFloat
    let utilityWidth: CGFloat
    let isCompact: Bool

    init(availableWidth: CGFloat, preferredWidth: CGFloat, isPresented: Bool) {
        let width = max(0, availableWidth)
        guard isPresented else {
            calendarWidth = width
            utilityWidth = 0
            isCompact = false
            return
        }
        let available = width - Tokens.Calendar.contentMinWidth - Tokens.Border.hairline
        isCompact = available < Tokens.Assistant.sidebarMinWidth
        if isCompact {
            calendarWidth = width
            utilityWidth = width
        } else {
            let preferred = preferredWidth.isFinite ? preferredWidth : Tokens.Assistant.sidebarWidth
            utilityWidth = min(max(preferred, Tokens.Assistant.sidebarMinWidth),
                               Tokens.Assistant.sidebarMaxWidth, available)
            calendarWidth = width - utilityWidth - Tokens.Border.hairline
        }
    }
}
