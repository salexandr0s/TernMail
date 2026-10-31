import MailStore
import SwiftUI

struct AccountPreferencesView: View {
    @Bindable var model: AccountPreferencesModel
    @State private var selectedID: String?

    var body: some View {
        if model.orderedRecords.isEmpty {
            ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.plus",
                description: Text("Add a Google account in Connections to set its preferences."))
        } else {
            SettingsPage {
                Section {
                    List(selection: $selectedID) {
                        ForEach(model.orderedRecords) { account in
                            accountRow(account).tag(account.id)
                        }
                        .onMove { offsets, destination in
                            Task { await model.move(fromOffsets: offsets, toOffset: destination) }
                        }
                    }
                    .frame(height: CGFloat(model.orderedRecords.count) * Tokens.Settings.accountRowHeight)
                    .environment(\.defaultMinListRowHeight, Tokens.Settings.accountRowHeight)
                    .scrollDisabled(true)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Accounts")
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Drag accounts to change their order in the sidebar.")
                }
                if let account = model.records.first(where: { $0.id == selectedID }) {
                    AccountPreferenceEditor(account: account, model: model).id(account.id)
                }
                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Tokens.Status.error)
                    }
                }
            }
            .onChange(of: model.orderedRecords.map(\.id), initial: true) { _, ids in
                if let selectedID, ids.contains(selectedID) { return }
                selectedID = ids.first
            }
        }
    }

    private func accountRow(_ account: AccountRecord) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            AddressAvatar(accountID: account.id, address: account.email, name: account.displayName ?? "")
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(model.displayName(for: account))
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, Tokens.Space.s1)
    }
}

private struct AccountPreferenceEditor: View {
    let account: AccountRecord
    @Bindable var model: AccountPreferencesModel
    @State private var nickname = ""
    @State private var nicknameWrite = LiveApplyScheduler()
    @AppStorage(AccountAppearance.storageKey) private var accountColors = Data()
    private let colors = ["Blue", "Pink", "Orange", "Green", "Purple", "Teal", "Indigo", "Brown"]

    var body: some View {
        Section("Appearance") {
            SettingsControlRow("Nickname", detail: "How this account appears in Tern. Saves as you type.") {
                HStack(spacing: Tokens.Space.s2) {
                    if nicknameWrite.isWaiting {
                        ProgressView().controlSize(.small).accessibilityLabel("Saving")
                    }
                    TextField("Nickname", text: $nickname, prompt: Text("Optional"))
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                        .onAppear { nickname = preferences.nickname ?? "" }
                        .onChange(of: nickname) { _, _ in
                            nicknameWrite.schedule { await commitNickname() }
                        }
                        .onDisappear {
                            let write = nicknameWrite
                            Task { await write.flush() }
                        }
                }
            }
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

        Section("Mail and profiles") {
            SettingsToggleRow("Sync Mail", detail: "Keeps cached mail and drafts. New mail, sending and snoozes wait while paused.", isOn: Binding(get: { preferences.syncEnabled }, set: { enabled in
                Task { await model.update(account.id) { $0.syncEnabled = enabled } }
            }))
            SettingsControlRow("Profile", detail: "This account also stays in All accounts.") {
                Picker("Profile", selection: Binding(get: { preferences.profileID ?? "" }, set: { id in
                    Task { await model.update(account.id) { $0.profileID = id.isEmpty ? nil : id } }
                })) {
                    Text("All accounts only").tag("")
                    ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
                .fixedSize()
            }
        }
    }

    private var preferences: AccountMailPreferences { model.preferences(for: account.id) }
    private var colorIndex: Int? { AccountAppearance.decode(accountColors)[account.id] }

    private func commitNickname() async {
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != (preferences.nickname ?? "") else { return }
        await model.update(account.id) { $0.nickname = value.isEmpty ? nil : value }
    }
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
