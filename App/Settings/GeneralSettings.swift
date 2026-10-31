import SwiftUI

struct GeneralSettings: View {
    @AppStorage(UndoSendDelay.key) private var undoSendDelay = UndoSendDelay.defaultSeconds
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsPage {
            Section("Default email app") {
                DefaultMailAppView()
            }
            Section("Sending") {
                SettingsControlRow("Undo Send", detail: "Delay sending so you can undo.") {
                    Picker("Undo Send delay", selection: $undoSendDelay) {
                        ForEach(UndoSendDelay.choices, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            Section("Keyboard") {
                SettingsToggleRow("Single-Key Shortcuts", detail: "Use letter keys when you aren't typing.", isOn: $usesSingleKeys)
                Button("All Keyboard Shortcuts…") {
                    openWindow(id: KeyboardShortcutsView.sceneID)
                }
                .buttonStyle(.link)
                .accessibilityHint("Opens the Keyboard Shortcuts window")
            }
        }
    }
}
