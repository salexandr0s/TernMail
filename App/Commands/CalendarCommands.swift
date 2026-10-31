import SwiftUI

/// The Calendar menu. Items act on the calendar in the focused main window
/// and disable while mail or attachments are showing.
struct CalendarCommands: Commands {
    @FocusedValue(\.calendarModel) private var calendar
    @FocusedValue(\.calendarActions) private var actions

    var body: some Commands {
        CommandMenu("Calendar") {
            Button("Today", systemImage: "calendar") { calendar?.date = .now }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.today.shortcut)
                .disabled(calendar == nil)
            Button("Go to Date…", systemImage: "calendar.badge.clock") { actions?.goToDate() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.goToDate.shortcut)
                .disabled(actions == nil)
            Divider()
            ForEach(CalendarDisplayMode.allCases) { mode in
                Toggle(mode.title, isOn: Binding(
                    get: { calendar?.mode == mode },
                    set: { if $0 { calendar?.mode = mode } }
                ))
                .keyboardShortcut(ShortcutCatalog.calendarMode(mode).shortcut)
                .disabled(calendar == nil)
            }
            Divider()
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await calendar?.refresh() } }
                .labelStyle(.titleAndIcon)
                .disabled(calendar == nil)
            Button("Calendar Activity…", systemImage: "list.bullet.clipboard") { actions?.showActivity() }
                .labelStyle(.titleAndIcon)
                .disabled(actions == nil)
            Button("Manage Calendars…", systemImage: "calendar.badge.checkmark") { actions?.showManagement() }
                .labelStyle(.titleAndIcon)
                .disabled(actions == nil)
            Divider()
            Button("Import Events…", systemImage: "square.and.arrow.down") { actions?.importEvents() }
                .labelStyle(.titleAndIcon)
                .disabled(actions == nil)
            Button("Export Displayed Events…", systemImage: "square.and.arrow.up") { actions?.exportEvents() }
                .labelStyle(.titleAndIcon)
                .disabled(actions == nil || calendar?.events.isEmpty != false)
            Menu("Export Calendar") {
                ForEach(exportableCalendars) { owner in
                    Button("\(owner.accountName) · \(owner.title)") { actions?.exportCalendar(owner) }
                }
            }
            .disabled(actions == nil || exportableCalendars.isEmpty)
        }
    }

    /// Calendars whose events the account may read in full.
    private var exportableCalendars: [CalendarDisplayCalendar] {
        calendar?.calendars.filter { $0.entry.canReadDetails } ?? []
    }
}
