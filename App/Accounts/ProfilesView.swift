import MailStore
import SwiftUI

struct ProfilesView: View {
    @Bindable var model: AccountPreferencesModel
    @State private var editing: MailProfile?
    @State private var deleting: MailProfile?

    var body: some View {
        SettingsPage {
            Section {
                HStack(spacing: Tokens.Space.s3) {
                    profileIcon("tray.2", color: .accentColor)
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text("All accounts").font(.body.weight(.medium))
                        Text("\(accountCount(model.records.count)) · Always includes every account")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Tokens.Space.s2)
                    if model.activeProfileID == nil { activeBadge }
                }
                .padding(.vertical, Tokens.Space.s1)
            }

            Section {
                if model.profiles.isEmpty { emptyProfiles }
                else {
                    ForEach(model.profiles) { profile in profileCard(profile) }
                }
            } header: {
                HStack {
                    Text("Your profiles")
                    Text("\(model.profiles.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Profile", systemImage: "plus") {
                        editing = MailProfile(name: "", sortOrder: model.profiles.count)
                    }
                    .controlSize(.small)
                }
            } footer: {
                Text("Assign accounts in Accounts → Preferences. Switch profiles from the mailbox toolbar. Each profile can have its own notification hours.")
            }

            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(Tokens.Status.error)
                }
            }
        }
        .sheet(item: $editing) { profile in ProfileEditor(profile: profile, model: model) }
        .ternConfirm("Delete this profile?", item: $deleting, actionTitle: "Delete Profile",
                     message: "Its accounts remain in All. Cached mail stays on this Mac.") { profile in
            Task { await model.deleteProfile(profile) }
        }
    }

    private var emptyProfiles: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            profileIcon("person.2", color: .secondary)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text("No profiles yet").font(.body)
                Text("Group accounts for work or personal mail, with notification hours for each profile.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Tokens.Space.s1)
    }

    private func profileCard(_ profile: MailProfile) -> some View {
        let accounts = model.orderedRecords.filter { model.preferences(for: $0.id).profileID == profile.id }
        return VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                profileIcon(profile.symbol, color: AccountAppearance.color(at: profile.colorIndex))
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(profile.name).font(.body.weight(.medium)).lineLimit(2)
                    Text(accountCount(accounts.count)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Tokens.Space.s2)
                if model.activeProfileID == profile.id { activeBadge }
                Button("Edit") { editing = profile }
                    .accessibilityLabel("Edit \(profile.name)")
                Menu {
                    Button("Delete Profile…", role: .destructive) { deleting = profile }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More options for \(profile.name)")
            }
            Divider()
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Label(accounts.isEmpty ? "No accounts assigned" : accounts.map { model.displayName(for: $0) }.joined(separator: ", "), systemImage: "envelope")
                    .lineLimit(2)
                Spacer(minLength: Tokens.Space.s2)
                Label(scheduleSummary(profile.notificationSchedule), systemImage: "bell")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, Tokens.Space.s1)
    }

    private var activeBadge: some View {
        Label("Active", systemImage: "checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func profileIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(color)
            .frame(width: Tokens.Space.s8, height: Tokens.Space.s8)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .accessibilityHidden(true)
    }

    private func accountCount(_ count: Int) -> String { count == 1 ? "1 account" : "\(count) accounts" }

    private func scheduleSummary(_ schedule: ProfileNotificationSchedule) -> String {
        switch schedule {
        case .unrestricted: "Any time"
        case .off: "Notifications off"
        case .everyDay: "Daily hours"
        case .weekdays: "Weekday hours"
        case .custom: "Custom hours"
        }
    }
}

private struct ProfileEditor: View {
    @State private var profile: MailProfile
    @Bindable var model: AccountPreferencesModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    private let symbols = [
        ("person.2", "People"), ("briefcase", "Work"), ("house", "Home"), ("leaf", "Leaf"),
        ("graduationcap", "Study"), ("star", "Star"), ("heart", "Heart"), ("tray.2", "Mail")
    ]
    private let colors = ["Blue", "Pink", "Orange", "Green", "Purple", "Teal", "Indigo", "Brown"]
    private var isNew: Bool { !model.profiles.contains { $0.id == profile.id } }

    @FocusState private var nameFocused: Bool

    init(profile: MailProfile, model: AccountPreferencesModel) {
        _profile = State(initialValue: profile); self.model = model
    }

    var body: some View {
        SettingsEditorSheet(
            title: isNew ? "New Profile" : "Edit Profile",
            messages: [profile.notificationSchedule.isValid ? nil : "Each range must end after it starts.", model.error].compactMap { $0 }
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                appearanceFields
                    .disabled(isSaving)
                Divider()
                ProfileScheduleView(schedule: $profile.notificationSchedule)
                    .disabled(isSaving)
            }
        } actions: {
            if isSaving { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(isNew ? "Create Profile" : "Save Changes") {
                isSaving = true
                Task {
                    if await model.saveProfile(profile) { dismiss() }
                    isSaving = false
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !profile.notificationSchedule.isValid)
        }
        .defaultFocus($nameFocused, true)
        .interactiveDismissDisabled(isSaving)
    }

    private var appearanceFields: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.Space.s3, verticalSpacing: Tokens.Space.s2) {
            GridRow {
                fieldLabel("Name")
                TextField("Work, Personal…", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Profile name")
                    .focused($nameFocused)
            }
            GridRow {
                fieldLabel("Icon")
                HStack(spacing: Tokens.Space.s2) {
                    ForEach(symbols, id: \.0) { symbol, title in
                        Button { profile.symbol = symbol } label: {
                            Image(systemName: symbol)
                                .font(.body)
                                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                                .background(profile.symbol == symbol ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                                        .strokeBorder(profile.symbol == symbol ? Color.accentColor : Color.clear, lineWidth: Tokens.Border.hairline)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(title).accessibilityLabel(title)
                        .accessibilityAddTraits(profile.symbol == symbol ? .isSelected : [])
                    }
                }
            }
            GridRow {
                fieldLabel("Color")
                HStack(spacing: Tokens.Space.s2) {
                    ForEach(AccountAppearance.palette.indices, id: \.self) { index in
                        Button { profile.colorIndex = index } label: {
                            Circle().fill(AccountAppearance.palette[index])
                                .frame(width: Tokens.Space.s5, height: Tokens.Space.s5)
                                .overlay {
                                    if profile.colorIndex == index {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                                    }
                                }
                                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(colors[index]).accessibilityLabel(colors[index])
                        .accessibilityAddTraits(profile.colorIndex == index ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).frame(width: Tokens.Settings.editorLabelWidth, alignment: .leading)
    }
}
