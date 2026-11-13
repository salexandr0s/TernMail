import SwiftUI

/// Calendar's period navigation, Today and view switcher. New Event uses
/// the workspace's shared create button.
struct CalendarToolbar: CustomizableToolbarContent {
    @Bindable var model: CalendarModel
    var isCompact = false
    /// A narrow window moves Today into the view menu.
    var foldsToday = false
    /// A window narrower still moves Previous and Next there too.
    var foldsNavigation = false
    /// Each item reads it here, because an inner `hidden(false)` would win
    /// over one applied to the whole group.
    var isVisible = true

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "calendar.navigation", placement: .primaryAction) {
            ControlGroup {
                previousButton.help("Previous \(model.mode.title.lowercased())")
                nextButton.help("Next \(model.mode.title.lowercased())")
            }
        }
        .mailToolbarVisible(isVisible && !foldsNavigation)
        ToolbarItem(id: "calendar.today", placement: .primaryAction) {
            Button { model.date = .now } label: {
                if isCompact { Image(systemName: "calendar.badge.clock") }
                else { Text("Today") }
            }
            .help("Today (\(ShortcutCatalog.today.label))")
            .accessibilityLabel("Today")
        }
        .mailToolbarVisible(isVisible && !foldsToday)
        ToolbarItem(id: "calendar.mode", placement: .primaryAction) {
            // A bare menu picker shows no title in the toolbar, so the menu
            // carries the current mode as its label.
            Menu {
                if foldsToday {
                    Group {
                        if foldsNavigation {
                            previousButton
                            nextButton
                        }
                        Button { model.date = .now } label: { Label("Today", systemImage: "calendar.badge.clock") }
                    }
                    .labelStyle(.titleAndIcon)
                    Divider()
                }
                Picker("View", selection: $model.mode) {
                    ForEach(CalendarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                if isCompact { Image(systemName: "calendar") }
                else { Text(model.mode.title) }
            }
            // Keep the current mode named while the toolbar has room.
            .labelStyle(.titleOnly)
            .menuIndicator(isCompact ? .hidden : .automatic)
            .fixedSize()
            .help(modeHelp)
            .accessibilityLabel("Calendar view")
            .accessibilityValue(model.mode.title)
        }
        .mailToolbarVisible(isVisible)
    }

    private var previousButton: some View {
        Button { model.shift(periods: -1) } label: {
            Label("Previous \(model.mode.title)", systemImage: "chevron.left")
        }
    }

    private var nextButton: some View {
        Button { model.shift(periods: 1) } label: {
            Label("Next \(model.mode.title)", systemImage: "chevron.right")
        }
    }

    private var modeHelp: String {
        let views = "Day, Week, Month, Year or Schedule"
        if foldsNavigation { return "\(model.mode.title) view. Go to another \(model.mode.title.lowercased()) or to today, or choose \(views)" }
        if foldsToday { return "\(model.mode.title) view. Go to today, or choose \(views)" }
        return isCompact ? "\(model.mode.title) view. Choose \(views)" : views
    }
}
