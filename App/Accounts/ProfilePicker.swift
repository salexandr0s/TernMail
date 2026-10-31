import SwiftUI

struct ProfilePicker: View {
    @Bindable var model: AccountPreferencesModel
    var body: some View {
        Picker("Profile", selection: Binding(model.activeProfileID, set: model.selectProfile)) {
            Label("All", systemImage: "tray.2").tag(String?.none)
            ForEach(model.profiles) { profile in Label(profile.name, systemImage: profile.symbol).tag(Optional(profile.id)) }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}
