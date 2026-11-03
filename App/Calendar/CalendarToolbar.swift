import SwiftUI

/// Calendar's period navigation, Today and view switcher. New Event uses
/// the workspace's shared create button.
struct CalendarToolbar: CustomizableToolbarContent {
    @Bindable var model: CalendarModel
    var isCompact = false

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "calendar.navigation", placement: .primaryAction) {
            ControlGroup {
                Button { model.shift(periods: -1) } label: {
                    Label("Previous \(model.mode.title)", systemImage: "chevron.left")
                }
                .help("Previous \(model.mode.title.lowercased())")
                Button { model.shift(periods: 1) } label: {
                    Label("Next \(model.mode.title)", systemImage: "chevron.right")
                }
                .help("Next \(model.mode.title.lowercased())")
            }
        }
        ToolbarItem(id: "calendar.today", placement: .primaryAction) {
            Button { model.date = .now } label: {
                if isCompact { Image(systemName: "calendar.badge.clock") }
                else { Text("Today") }
            }
            .help("Today (\(ShortcutCatalog.today.label))")
            .accessibilityLabel("Today")
        }
        ToolbarItem(id: "calendar.mode", placement: .primaryAction) {
            // A bare menu picker shows no title in the toolbar, so the menu
            // carries the current mode as its label.
            Menu {
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
            .help(isCompact ? "\(model.mode.title) view. Choose Day, Week, Month, Year or Schedule"
                : "Day, Week, Month, Year or Schedule")
            .accessibilityLabel("Calendar view")
            .accessibilityValue(model.mode.title)
        }
    }
}
