import SwiftUI

struct ProfilePicker: View {
    @Bindable var model: AccountPreferencesModel
    var body: some View {
        Picker("Profile", selection: Binding(get: { model.activeProfileID ?? "" }, set: { model.selectProfile($0.isEmpty ? nil : $0) })) {
            Label("All", systemImage: "tray.2").tag("")
            ForEach(model.profiles) { profile in Label(profile.name, systemImage: profile.symbol).tag(profile.id) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}
