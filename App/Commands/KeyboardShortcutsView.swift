import SwiftUI

/// Help ▸ Keyboard Shortcuts: the menu shortcuts by menu, then the single keys.
struct KeyboardShortcutsView: View {
    static let sceneID = "keyboard-shortcuts"

    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sections = matchingSections
        let singleKeys = SingleKeyShortcuts.keys.filter { matches($0.title, keys: $0.label, section: "Single-Key Shortcuts") }
        let destinations = SingleKeyShortcuts.destinationKeys.filter { matches($0.title, keys: "g then \($0.label)", section: "Single-Key Shortcuts") }
        let count = sections.reduce(0) { $0 + $1.commands.count } + singleKeys.count + destinations.count
        VStack(alignment: .leading, spacing: 0) {
            TernPageHeader(title: "Keyboard Shortcuts", subtitle: "Find a command by name, key, menu, or window.")
                .padding(Tokens.Workspace.pageGutter)
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityLabel("Search keyboard shortcuts")
                    .accessibilityIdentifier("shortcuts.search")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear shortcut search")
                }
            }
            .padding(.horizontal, Tokens.Workspace.pageGutter)
            .padding(.bottom, Tokens.Space.s4)
            Divider()
            if count == 0 {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.menu.rawValue) {
                            ForEach(section.commands) { command in
                                shortcutRow(command.title, keys: command.label, context: scopeHint(command))
                            }
                        }
                    }
                    if !singleKeys.isEmpty || !destinations.isEmpty {
                        Section {
                            ForEach(singleKeys, id: \.title) { key in
                                shortcutRow(key.title, keys: key.label)
                            }
                            ForEach(destinations, id: \.title) { key in
                                shortcutRow(key.title, keys: "g then \(key.label)")
                            }
                        } header: {
                            Text("Single-Key Shortcuts")
                        } footer: {
                            Text("Use these in the main window when you aren't typing.")
                        }
                    }
                }
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, Tokens.Settings.rowHeight)
            }
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Toggle(isOn: $usesSingleKeys) {
                    Text("Single-Key Shortcuts")
                    Text("Use letter keys in the main window when you aren't typing.")
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("shortcuts.singleKeys")
                Button("Keyboard Settings…") {
                    SettingsNavigationRequests.shared.request(.general)
                    openSettings()
                }
                .buttonStyle(.link)
                .accessibilityHint("Opens General settings")
            }
            .padding(Tokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surface.muted)
        }
        .background(Tokens.Surface.canvas)
        .frame(minWidth: Tokens.Layout.shortcutsWidth, idealWidth: Tokens.Layout.readableWidth, maxWidth: .infinity,
               minHeight: Tokens.Layout.windowMinHeight, idealHeight: Tokens.Layout.shortcutsHeight, maxHeight: .infinity)
        .onAppear { searchFocused = true }
    }

    private var matchingSections: [ShortcutCatalog.MenuSection] {
        ShortcutCatalog.sections.compactMap { section in
            let commands = section.commands.filter {
                matches($0.title, keys: $0.label, section: "\(section.menu.rawValue) \(scopeHint($0) ?? "")")
            }
            return commands.isEmpty ? nil : .init(menu: section.menu, commands: commands)
        }
    }

    private func matches(_ title: String, keys: String, section: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        let namedKeys = keys.replacingOccurrences(of: "⌘", with: " command cmd ")
            .replacingOccurrences(of: "⌥", with: " option alt ")
            .replacingOccurrences(of: "⌃", with: " control ctrl ")
            .replacingOccurrences(of: "⇧", with: " shift ")
            .replacingOccurrences(of: "⌫", with: " delete backspace ")
        let text = "\(title) \(keys) \(namedKeys) \(section)"
        return words.allSatisfy { text.localizedStandardContains(String($0)) }
    }

    private func scopeHint(_ command: ShortcutCatalog.Command) -> String? {
        if command.scopes == ShortcutCatalog.Scope.all { return nil }
        if command.scopes == ShortcutCatalog.Scope.mainWindow { return "Main window" }
        if command.scopes == ShortcutCatalog.Scope.all.subtracting([.assistant]) { return "Outside the Assistant window" }
        return ShortcutCatalog.Scope.allCases.filter { command.scopes.contains($0) }.map { scope in
            switch scope {
            case .mail: "Mail"
            case .calendar: "Calendar"
            case .attachments: "Attachments"
            case .conversation: "Conversation windows"
            case .compose: "Compose"
            case .settings: "Settings editors"
            case .assistant: "Assistant window"
            }
        }.formatted(.list(type: .and))
    }

    private func shortcutRow(_ title: String, keys: String, context: String? = nil) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.body.weight(.medium))
                if let context { Text(context).font(.callout).foregroundStyle(.secondary) }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Tokens.Space.s2)
            Text(keys)
                .font(.callout.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, Tokens.Space.s1_5)
                .padding(.vertical, Tokens.Space.s0_5)
                .frame(minWidth: Tokens.Space.s16)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .fixedSize()
        }
        .padding(.vertical, Tokens.Space.s1)
        .accessibilityElement(children: .combine)
    }
}
