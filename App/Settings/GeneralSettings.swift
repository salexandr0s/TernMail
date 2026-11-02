import SwiftUI

struct GeneralSettings: View {
    @AppStorage(UndoSendDelay.key) private var undoSendDelay = UndoSendDelay.defaultSeconds
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsPage {
            Section("Email links") {
                DefaultMailAppView()
            }
            Section {
                SettingsControlRow("Undo Send", detail: "Time to stop a message after choosing Send.") {
                    Picker("Undo Send delay", selection: $undoSendDelay) {
                        ForEach(UndoSendDelay.choices, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Sending")
            } footer: {
                Text("Tern holds each message for \(sendDelay) seconds. Choose Undo Send during that time to return to your draft.")
            }
            Section {
                SettingsToggleRow("Single-Key Shortcuts", detail: "Use letter keys when you aren't typing.", isOn: $usesSingleKeys)
            } header: {
                Text("Keyboard")
            } footer: {
                Text(usesSingleKeys ? "Single keys are on in the main window. Command-key shortcuts remain available."
                    : "Command-key shortcuts work with this setting off.")
            }
            Section("Everyday shortcuts") {
                ForEach([ShortcutCatalog.newMessage, ShortcutCatalog.reply, ShortcutCatalog.archive]) { command in
                    LabeledContent(command.title) {
                        Text(command.label).font(.body.monospaced().weight(.medium))
                    }
                }
                SettingsControlRow("All commands") {
                    Button("View Shortcuts…") {
                        openWindow(id: KeyboardShortcutsView.sceneID)
                    }
                    .accessibilityLabel("View all keyboard shortcuts")
                    .accessibilityHint("Opens the Keyboard Shortcuts window")
                }
            }
        }
    }

    private var sendDelay: Int {
        UndoSendDelay.choices.contains(undoSendDelay) ? undoSendDelay : UndoSendDelay.defaultSeconds
    }
}
