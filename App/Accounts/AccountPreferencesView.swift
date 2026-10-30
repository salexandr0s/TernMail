import MailStore
import SwiftUI

struct AccountPreferencesView: View {
    @Bindable var model: AccountPreferencesModel
    @State private var selectedID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Picker("Account", selection: $selectedID) {
                ForEach(model.orderedRecords) { account in Text(account.email).tag(account.id) }
            }
            if let account = model.records.first(where: { $0.id == selectedID }) {
                AccountPreferenceEditor(account: account, model: model).id(account.id)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(Tokens.Space.s4)
        .onChange(of: model.orderedRecords.map(\.id), initial: true) { _, ids in
            if !ids.contains(selectedID) { selectedID = ids.first ?? "" }
        }
    }
}

private struct AccountPreferenceEditor: View {
    let account: AccountRecord
    @Bindable var model: AccountPreferencesModel
    @State private var nickname = ""
    @AppStorage(AccountAppearance.storageKey) private var accountColors = Data()

    var body: some View {
        Form {
            HStack {
                TextField("Nickname", text: $nickname)
                Button("Save") {
                    let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await model.update(account.id) { $0.nickname = value.isEmpty ? nil : value } }
                }
                .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines) == (preferences.nickname ?? ""))
            }
            HStack {
                Text("Color")
                Spacer()
                ForEach(AccountAppearance.palette.indices, id: \.self) { index in
                    Button {
                        var values = AccountAppearance.decode(accountColors)
                        values[account.id] = index
                        accountColors = AccountAppearance.encode(values)
                    } label: {
                        Circle().fill(AccountAppearance.palette[index])
                            .frame(width: Tokens.Control.icon, height: Tokens.Control.icon)
                            .overlay { if colorIndex == index { Image(systemName: "checkmark").font(.caption2).foregroundStyle(.white) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Account color \(index + 1)")
                    .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                }
            }
            Toggle("Sync mail", isOn: Binding(get: { preferences.syncEnabled }, set: { enabled in
                Task { await model.update(account.id) { $0.syncEnabled = enabled } }
            }))
            Text("Pausing keeps cached mail and drafts. New mail, sending and snoozes wait until you resume.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Profile", selection: Binding(get: { preferences.profileID ?? "" }, set: { id in
                Task { await model.update(account.id) { $0.profileID = id.isEmpty ? nil : id } }
            })) {
                Text("All only").tag("")
                ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
            }
            HStack {
                Text("Account order")
                Spacer()
                Button("Move Up", systemImage: "arrow.up") { Task { await model.move(account.id, by: -1) } }
                    .disabled(model.orderedRecords.first?.id == account.id)
                Button("Move Down", systemImage: "arrow.down") { Task { await model.move(account.id, by: 1) } }
                    .disabled(model.orderedRecords.last?.id == account.id)
            }
        }
        .formStyle(.grouped)
        .onAppear { nickname = preferences.nickname ?? "" }
    }

    private var preferences: AccountMailPreferences { model.preferences(for: account.id) }
    private var colorIndex: Int? { AccountAppearance.decode(accountColors)[account.id] }
}

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
