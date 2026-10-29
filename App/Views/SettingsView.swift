import SwiftUI

/// Tern > Settings.
struct SettingsView: View {
    @AppStorage(UndoSendDelay.key) private var undoSendDelay = UndoSendDelay.defaultSeconds

    var body: some View {
        Form {
            Picker("Undo send delay:", selection: $undoSendDelay) {
                ForEach(UndoSendDelay.choices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .pickerStyle(.menu)
            Text("Tern waits this long before sending, so you can undo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.s6)
        .fixedSize()
    }
}
