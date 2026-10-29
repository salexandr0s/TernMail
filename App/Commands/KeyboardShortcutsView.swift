import SwiftUI

/// Help ▸ Keyboard Shortcuts: the menu shortcuts and the single keys.
struct KeyboardShortcutsView: View {
    static let sceneID = "keyboard-shortcuts"
    private static let width: CGFloat = 420
    private static let height: CGFloat = 560

    /// Menu items with shortcuts, by their menu titles.
    private static let menuShortcuts: [(title: String, keys: String)] = [
        ("New Message", "⌘N"),
        ("Send", "⇧⌘D"),
        ("Reply", "⌘R"),
        ("Reply All", "⇧⌘R"),
        ("Forward", "⇧⌘F"),
        ("Archive", "⌃⌘A"),
        ("Move to Trash", "⌘⌫"),
        ("Mark as Read or Unread", "⇧⌘U"),
        ("Star or Remove Star", "⇧⌘L"),
        ("Edit Labels", "⌥⌘L"),
        ("Move to", "⌃⌘M"),
        ("Snooze", "⌃⌘B"),
        ("Search Mail", "⌥⌘F"),
        ("Check for New Mail", "⇧⌘N"),
        ("New Label", "⌥⌘N"),
        ("Inbox, Starred, Snoozed, Sent, Drafts", "⌘1 to ⌘5"),
        ("Attach Files", "⇧⌘A"),
        ("Undo", "⌘Z"),
    ]

    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false

    var body: some View {
        Form {
            Section("Menu shortcuts") {
                ForEach(Self.menuShortcuts, id: \.title) { shortcut in
                    LabeledContent(shortcut.title, value: shortcut.keys)
                }
            }
            Section {
                ForEach(SingleKeyShortcuts.keys, id: \.title) { key in
                    LabeledContent(key.title, value: key.label)
                }
                ForEach(SingleKeyShortcuts.destinationKeys, id: \.title) { key in
                    LabeledContent(key.title, value: "g then \(key.label)")
                }
            } header: {
                Text("Single keys")
            } footer: {
                Text(usesSingleKeys
                    ? "On. They work in the main window while you aren't typing."
                    : "Off. Turn them on in Settings.")
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width, height: Self.height)
    }
}
