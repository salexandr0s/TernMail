import MailStore
import SwiftUI

struct AccountPreferencesView: View {
    @Bindable var model: AccountPreferencesModel
    @State private var selectedID = ""

    var body: some View {
        SettingsPage {
            if model.orderedRecords.isEmpty {
                HStack(alignment: .top, spacing: Tokens.Space.s3) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    SettingsRowLabel("No accounts", detail: "Add a Google account in Connections to set its preferences.")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s3)
                .settingsSurface()
            } else {
                SettingsControlRow("Account") {
                    Picker("Account", selection: $selectedID) {
                        ForEach(model.orderedRecords) { account in Text(account.email).tag(account.id) }
                    }
                    .labelsHidden()
                }
                .settingsSurface()
                if let account = model.records.first(where: { $0.id == selectedID }) {
                    AccountPreferenceEditor(account: account, model: model).id(account.id)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
        }
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
    private let colors = ["Blue", "Pink", "Orange", "Green", "Purple", "Teal", "Indigo", "Brown"]

    var body: some View {
        SettingsGroup("Appearance", systemImage: "paintpalette") {
            SettingsControlRow("Nickname", detail: "How this account appears in Tern.") {
                HStack(spacing: Tokens.Space.s2) {
                    TextField("Nickname", text: $nickname)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: Tokens.Settings.editorLabelWidth, maxWidth: .infinity)
                    Button("Save") {
                        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await model.update(account.id) { $0.nickname = value.isEmpty ? nil : value } }
                    }
                    .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines) == (preferences.nickname ?? ""))
                }
            }
            Divider().padding(.horizontal, Tokens.Space.s4)
            SettingsControlRow("Account color") {
                HStack(spacing: Tokens.Space.s1) {
                    ForEach(AccountAppearance.palette.indices, id: \.self) { index in
                        Button {
                            var values = AccountAppearance.decode(accountColors)
                            values[account.id] = index
                            accountColors = AccountAppearance.encode(values)
                        } label: {
                            Circle().fill(AccountAppearance.palette[index])
                                .frame(width: Tokens.Space.s5, height: Tokens.Space.s5)
                                .overlay {
                                    if colorIndex == index {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    }
                                }
                                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(colors[index]).accessibilityLabel(colors[index])
                        .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
                    }
                }
            }
        }
        .onAppear { nickname = preferences.nickname ?? "" }

        SettingsGroup("Mail and profiles", systemImage: "tray.2") {
            SettingsToggleRow("Sync mail", detail: "Keeps cached mail and drafts. New mail, sending and snoozes wait while paused.", isOn: Binding(get: { preferences.syncEnabled }, set: { enabled in
                Task { await model.update(account.id) { $0.syncEnabled = enabled } }
            }))
            Divider().padding(.horizontal, Tokens.Space.s4)
            SettingsControlRow("Profile", detail: "This account also stays in All accounts.") {
                Picker("Profile", selection: Binding(get: { preferences.profileID ?? "" }, set: { id in
                    Task { await model.update(account.id) { $0.profileID = id.isEmpty ? nil : id } }
                })) {
                    Text("All accounts only").tag("")
                    ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
                .labelsHidden()
            }
            Divider().padding(.horizontal, Tokens.Space.s4)
            SettingsControlRow("Account order", detail: "Position in the sidebar.") {
                HStack(spacing: Tokens.Space.s2) {
                    Button("Move Up", systemImage: "arrow.up") { Task { await model.move(account.id, by: -1) } }
                        .disabled(model.orderedRecords.first?.id == account.id)
                    Button("Move Down", systemImage: "arrow.down") { Task { await model.move(account.id, by: 1) } }
                        .disabled(model.orderedRecords.last?.id == account.id)
                }
            }
        }
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
