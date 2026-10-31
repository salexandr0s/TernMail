import SwiftUI

/// The toolbar items the main window shows while Calendar is active: period
/// navigation, Today, the view switcher and New Event. They sit between the
/// section pop-up and the search field, so they stay narrow.
struct CalendarToolbar: CustomizableToolbarContent {
    @Bindable var model: CalendarModel

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "calendar.navigation", placement: .automatic) {
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
        ToolbarItem(id: "calendar.today", placement: .automatic) {
            Button("Today") { model.date = .now }
                .help("Today (\(ShortcutCatalog.today.label))")
        }
        ToolbarItem(id: "calendar.mode", placement: .automatic) {
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
        ToolbarItem(id: "calendar.newEvent", placement: .automatic) {
            Button { model.beginNew(on: model.date) } label: {
                Label("New Event", systemImage: "plus")
            }
            .help("New Event (\(ShortcutCatalog.newEvent.label))")
            .disabled(!model.calendars.contains(where: \.canWrite))
        }
    }
}
