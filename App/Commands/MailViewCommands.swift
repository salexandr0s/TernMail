import AppKit
import MailStore
import MessageContent
import SwiftUI

extension FocusedValues {
    @Entry var conversationLink: MailLink?
    @Entry var readerAppearance: ReaderAppearance?
}

/// View ▸ Show with Light Background for the conversation in front. The
/// reader offers it while Dark Mode adapts mail; the choice is kept for each
/// of the conversation's senders.
struct ReaderAppearance {
    let showsLightBackground: Bool
    let toggle: @MainActor () -> Void
}

/// The View menu.
struct MailViewCommands: Commands {
    @FocusedValue(\.readerActions) private var reader
    @FocusedValue(\.readerAppearance) private var appearance
    @FocusedValue(\.sidebarToggle) private var sidebar
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
            Toggle("Show with Light Background", isOn: Binding(appearance?.showsLightBackground ?? false) { _ in appearance?.toggle() })
                .disabled(appearance == nil)
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
