import SwiftUI

struct GeneralSettings: View {
    @AppStorage(UndoSendDelay.key) private var undoSendDelay = UndoSendDelay.defaultSeconds
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                SettingsGroup("Email links", systemImage: "envelope") {
                    DefaultMailAppView().padding(Tokens.Space.s3)
                }
                SettingsGroup("Sending", systemImage: "paperplane") {
                    HStack(spacing: Tokens.Space.s3) {
                        SettingsRowLabel("Undo Send", detail: "Wait before sending so you can undo.")
                        Spacer(minLength: Tokens.Space.s3)
                        Picker("Undo Send", selection: $undoSendDelay) {
                            ForEach(UndoSendDelay.choices, id: \.self) { seconds in
                                Text("\(seconds) seconds").tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Undo Send delay")
                    }
                    .padding(Tokens.Space.s3)
                }

                SettingsGroup("Keyboard", systemImage: "keyboard") {
                    HStack(spacing: Tokens.Space.s3) {
                        SettingsRowLabel("Single-key shortcuts", detail: "Use letter keys when you aren't typing.")
                        Spacer(minLength: Tokens.Space.s3)
                        Toggle("Single-key shortcuts", isOn: $usesSingleKeys)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .fixedSize()
                            .accessibilityLabel("Single-key shortcuts")
                            .accessibilityHint("Use letter keys when you aren't typing.")
                    }
                    .padding(Tokens.Space.s3)

                    Divider()
                        .padding(.horizontal, Tokens.Space.s3)

                    HStack {
                        Button("View Shortcuts…") {
                            openWindow(id: KeyboardShortcutsView.sceneID)
                        }
                        .buttonStyle(.link)
                        .accessibilityHint("Opens Keyboard Shortcuts")
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Tokens.Space.s3)
                    .padding(.vertical, Tokens.Space.s2)
                }
            }
            .padding(Tokens.Space.s4)
        }
    }
}

