import SwiftUI

/// Optional toolbar copies of the commands in Calendar's page header.
/// Keep their identifiers available for existing toolbar customizations.
struct CalendarToolbar: CustomizableToolbarContent {
    @Bindable var model: CalendarModel

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
        .defaultCustomization(.hidden)
        ToolbarItem(id: "calendar.today", placement: .primaryAction) {
            Button("Today") { model.date = .now }
                .help("Today (\(ShortcutCatalog.today.label))")
        }
        .defaultCustomization(.hidden)
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
                Text(model.mode.title)
            }
            // Toolbars hide menu titles by default; the current mode is the whole point here.
            .labelStyle(.titleOnly)
            .fixedSize()
            .help("Day, Week, Month, Year or Schedule")
            .accessibilityLabel("Calendar view")
            .accessibilityValue(model.mode.title)
        }
        .defaultCustomization(.hidden)
    }
}
