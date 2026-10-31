import SwiftUI

/// Help ▸ Keyboard Shortcuts: the menu shortcuts by menu, then the single keys.
struct KeyboardShortcutsView: View {
    static let sceneID = "keyboard-shortcuts"

    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false

    var body: some View {
        List {
            ForEach(ShortcutCatalog.sections) { section in
                Section(section.menu.rawValue) {
                    ForEach(section.commands) { command in
                        shortcutRow(command.title, keys: command.label)
                    }
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
                Text("Single-Key Shortcuts")
            } footer: {
                Text(usesSingleKeys
                    ? "On in the main window when you aren't typing."
                    : "Off. Enable in Settings.")
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, Tokens.Settings.rowHeight)
        .frame(width: Tokens.Layout.shortcutsWidth, height: Tokens.Layout.shortcutsHeight)
    }

    private func shortcutRow(_ title: String, keys: String) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Tokens.Space.s2)
            Text(keys)
                .font(.callout.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, Tokens.Space.s1_5)
                .padding(.vertical, Tokens.Space.s0_5)
                .frame(minWidth: Tokens.Space.s16)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .accessibilityElement(children: .combine)
    }
}
