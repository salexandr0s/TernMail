import SwiftUI

/// Shows mail from one profile's accounts, or from every account. The toolbar
/// shows the active profile's name unless the window is compact.
struct ProfilePicker: View {
    @Bindable var model: AccountPreferencesModel
    var isCompact = false

    var body: some View {
        let active = model.profiles.first { $0.id == model.activeProfileID }
        Menu {
            Picker("Profile", selection: Binding(model.activeProfileID, set: model.selectProfile)) {
                Label("All Accounts", systemImage: "tray.2").tag(String?.none)
                ForEach(model.profiles) { profile in Label(profile.name, systemImage: profile.symbol).tag(Optional(profile.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            let label = Label(active?.name ?? "All Accounts", systemImage: active?.symbol ?? "tray.2")
            // Toolbars hide menu titles by default; the active profile is what this menu says.
            if isCompact { label.labelStyle(.iconOnly) } else { label.labelStyle(.titleAndIcon) }
        }
        .fixedSize()
        .help("Show mail from one profile's accounts")
        .accessibilityLabel("Profile")
        .accessibilityValue(active?.name ?? "All Accounts")
    }
}
