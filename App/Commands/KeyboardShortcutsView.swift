import SwiftUI

/// Help ▸ Keyboard Shortcuts: the menu shortcuts and the single keys.
struct KeyboardShortcutsView: View {
    static let sceneID = "keyboard-shortcuts"

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
                    shortcutRow(shortcut.title, keys: shortcut.keys)
                }
            }
            Section {
                ForEach(SingleKeyShortcuts.keys, id: \.title) { key in
                    shortcutRow(key.title, keys: key.label)
                }
                ForEach(SingleKeyShortcuts.destinationKeys, id: \.title) { key in
                    shortcutRow(key.title, keys: "g then \(key.label)")
                }
            } header: {
                Text("Single-key shortcuts")
            } footer: {
                Text(usesSingleKeys
                    ? "On in the main window when you aren't typing."
                    : "Off. Enable in Settings.")
            }
        }
        .formStyle(.grouped)
        .frame(width: Tokens.Layout.shortcutsWidth, height: Tokens.Layout.shortcutsHeight)
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        LabeledContent {
            Text(keys)
                .font(.callout.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, Tokens.Space.s2)
                .padding(.vertical, Tokens.Space.s1)
                .frame(minWidth: Tokens.Space.s16)
                .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline)
                }
        } label: {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
