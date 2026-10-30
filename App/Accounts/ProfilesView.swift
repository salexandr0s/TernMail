import MailStore
import SwiftUI

struct ProfilesView: View {
    @Bindable var model: AccountPreferencesModel
    @State private var editing: MailProfile?
    @State private var deleting: MailProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                Text("Profiles group accounts for the mailbox and notifications.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Add Profile", systemImage: "plus") { editing = MailProfile(name: "", sortOrder: model.profiles.count) }
            }
            List {
                Label("All accounts", systemImage: "tray.2")
                ForEach(model.profiles) { profile in
                    HStack {
                        Label(profile.name, systemImage: profile.symbol).foregroundStyle(AccountAppearance.color(at: profile.colorIndex))
                        Spacer()
                        Button("Edit") { editing = profile }
                        Button("Delete", role: .destructive) { deleting = profile }
                    }
                }
            }
            Text("Assign each account to a profile in Account Preferences. All always includes every account.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(Tokens.Space.s4)
        .sheet(item: $editing) { profile in ProfileEditor(profile: profile, model: model) }
        .confirmationDialog("Delete this profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Profile", role: .destructive) { if let deleting { Task { await model.deleteProfile(deleting) } }; deleting = nil }
        } message: { Text("Its accounts remain in All. Cached mail stays on this Mac.") }
    }
}

private struct ProfileEditor: View {
    @State var profile: MailProfile
    @Bindable var model: AccountPreferencesModel
    @Environment(\.dismiss) private var dismiss
    private let symbols = ["person.2", "briefcase", "house", "leaf", "graduationcap", "star", "heart", "tray.2"]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Profile").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $profile.name)
                Picker("Symbol", selection: $profile.symbol) {
                    ForEach(symbols, id: \.self) { symbol in Label(symbol, systemImage: symbol).tag(symbol) }
                }
                Picker("Color", selection: $profile.colorIndex) {
                    ForEach(AccountAppearance.palette.indices, id: \.self) { index in Text("Color \(index + 1)").tag(index) }
                }
            }
            .formStyle(.grouped)
            ProfileScheduleView(schedule: $profile.notificationSchedule)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { Task { if await model.saveProfile(profile) { dismiss() } } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !profile.notificationSchedule.isValid)
            }
        }
        .padding(Tokens.Space.s4)
        .frame(width: Tokens.Layout.settingsWidth, height: Tokens.Assistant.settingsHeight)
    }
}
