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
                        SettingsErrorLabel(error)
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
                    .truncationMode(.middle)
                    .help(model.displayName(for: account))
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(account.email)
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

    var body: some View {
        Section("Appearance") {
            SettingsControlRow("Nickname", detail: "How this account appears in Tern. Saves as you type.") {
                HStack(spacing: Tokens.Space.s2) {
                    if nicknameWrite.isWaiting {
                        ProgressView().controlSize(.small).accessibilityLabel("Saving")
                    }
                    TextField("Nickname", text: $nickname, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
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
                SwatchPicker(selection: Binding(colorIndex, set: { index in
                    var values = AccountAppearance.decode(accountColors)
                    values[account.id] = index
                    accountColors = AccountAppearance.encode(values)
                }))
            }
        }

        Section("Mail and profiles") {
            SettingsAsyncToggleRow("Sync Mail", detail: "Keeps cached mail and drafts. New mail, sending and snoozes wait while paused.",
                                   isOn: preferences.syncEnabled) { enabled in
                await model.update(account.id) { $0.syncEnabled = enabled }
            }
            SettingsControlRow("Profile", detail: "This account also stays in All accounts.") {
                Picker("Profile", selection: Binding(preferences.profileID, set: { id in
                    Task { await model.update(account.id) { $0.profileID = id } }
                })) {
                    Text("All accounts only").tag(String?.none)
                    ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                .frame(maxWidth: Tokens.Settings.pickerWidth)
                .help(model.profiles.first(where: { $0.id == preferences.profileID })?.name ?? "All accounts only")
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
