import AppKit
import MailStore
import MessageContent
import SwiftUI

extension FocusedValues {
    @Entry var conversationLink: MailLink?
}

/// The View menu and the app's Window menu additions.
struct MailViewCommands: Commands {
    @FocusedValue(\.mailboxModel) private var mailbox
    @FocusedValue(\.readerActions) private var reader
    @FocusedValue(\.sidebarToggle) private var sidebar
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MailWindowPreferences.hidesReaderKey) private var hidesReader = false
    @AppStorage("showMessageSize") private var showsMessageSize = false

    var body: some Commands {
        ToolbarCommands()
        CommandGroup(after: .toolbar) {
            Button(sidebar?.isVisible == true ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") { sidebar?.toggle() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.toggleSidebar.shortcut)
                .disabled(sidebar == nil)
            Toggle("Show Viewing Pane", isOn: $hidesReader.negated())
                .keyboardShortcut(ShortcutCatalog.toggleReader.shortcut)
            MessageListDensityPicker()
            MessageListViewOptions()
            Toggle("Message Size", isOn: $showsMessageSize)
            Divider()
            Button("Expand All Messages", systemImage: "rectangle.expand.vertical") { reader?.expandAll() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.expandAll.shortcut)
                .disabled(!(reader?.canExpand ?? false))
            Button("Collapse All Messages", systemImage: "rectangle.compress.vertical") { reader?.collapseAll() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.collapseAll.shortcut)
                .disabled(!(reader?.canCollapse ?? false))
        }
        CommandGroup(after: .windowArrangement) {
            Button("Tern", systemImage: "envelope") { openWindow(id: "main") }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.mainWindow.shortcut)
            Button("Assistant", systemImage: "sparkles") { AssistantWindow.open(using: openWindow, fullScreen: false) }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(ShortcutCatalog.assistant.shortcut)
        }
    }
}

/// View ▸ Density, as a submenu with a check on the current choice.
private struct MessageListDensityPicker: View {
    @Bindable private var preferences = MessageListPreferences.shared

    var body: some View {
        Picker("Density", selection: $preferences.density) {
            ForEach(MailListDensity.allCases) { Text($0.title).tag($0) }
        }
    }
}
