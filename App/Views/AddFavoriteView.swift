import MailStore
import SwiftUI

/// A folder keeps its account scope even when another account uses the same label ID.
struct FavoriteFolderOption: Identifiable {
    let target: MailFavoriteTarget
    let title: String
    let systemImage: String
    var label: LabelRecord?
    var id: MailFavoriteTarget { target }

    var isLabel: Bool { label != nil }

    static func choices(accountID: String?, labels: [LabelRecord]) -> [FavoriteFolderOption] {
        let labels = labels.filter { (accountID == nil || $0.accountID == accountID) && !LabelRules.isTemporary($0.id) }
        let scope: MailSearchScope = accountID.map { .accounts([$0]) } ?? .allAccounts
        let primary = SystemMailbox.all + [.outbox]
        let primaryIDs = Set(primary.map(\.id))
        let extraIDs = Set(labels.filter(\.isSystem).map(\.id)).subtracting(primaryIDs)
        let known = SystemMailbox.more.filter { extraIDs.contains($0.id) }
        let other = extraIDs.subtracting(known.map(\.id)).map(SystemMailbox.init(labelID:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        var choices = (primary + known + other).map {
            FavoriteFolderOption(target: .mailbox(labelID: $0.id, scope: scope), title: $0.title, systemImage: $0.systemImage)
        }
        if let accountID {
            choices += labels.filter { !$0.isSystem }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { FavoriteFolderOption(target: .label(accountID: accountID, labelID: $0.id), title: $0.name, systemImage: "tag", label: $0) }
        }
        return choices
    }
}

struct AddFavoriteView: View {
    let mailbox: MailboxModel
    let onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccount = ""
    @State private var selectedTarget: MailFavoriteTarget?
    @State private var query = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var searchFocused: Bool

    private var options: [FavoriteFolderOption] {
        let accounts = mailbox.presentedAccounts
        guard !accounts.isEmpty, selectedAccount.isEmpty || accounts.contains(where: { $0.account.id == selectedAccount }) else { return [] }
        return FavoriteFolderOption.choices(accountID: selectedAccount.isEmpty ? nil : selectedAccount, labels: accounts.flatMap(\.labels))
    }

    private var visibleOptions: [FavoriteFolderOption] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter { text.isEmpty || $0.title.localizedStandardContains(text) }
    }

    private func isAdded(_ target: MailFavoriteTarget) -> Bool {
        mailbox.navigation.favorites.contains { target.matchesFavorite($0.target) }
    }

    private var canAdd: Bool {
        guard let selectedTarget else { return false }
        return !isSaving && !mailbox.navigation.isSaving && !isAdded(selectedTarget)
            && visibleOptions.contains { $0.target == selectedTarget }
    }

    var body: some View {
        SettingsEditorSheet(title: "Add Favorite", width: Tokens.Settings.editorWideWidth, scrolls: false) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                accountPicker
                HStack(spacing: Tokens.Space.s3) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Find a folder or label", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($searchFocused)
                        .accessibilityLabel("Find a folder or label")
                        .accessibilityIdentifier("favorites.searchFolders")
                    if !query.isEmpty {
                        Button("Clear Folder Search", systemImage: "xmark.circle.fill", action: clearSearch)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Tokens.Space.s4)
                .ternSurface(style: .grouped)
                .ternOutline(radius: Tokens.Radius.lg, focus: searchFocused ? .accentColor : nil)
                folderList
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Tokens.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("favorites.saveError")
                }
            }
            .padding(.horizontal, Tokens.Workspace.pageGutter)
            .padding(.vertical, Tokens.Space.s4)
            .disabled(isSaving)
        } actions: {
            if isSaving { ProgressView().controlSize(.small).accessibilityLabel("Adding favorite") }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button("Add Favorite") { Task { await add() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
                .accessibilityIdentifier("favorites.confirmAdd")
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { searchFocused = true }
        .onChange(of: selectedAccount) { _, _ in
            selectedTarget = nil
            saveError = nil
        }
        .onChange(of: visibleOptions.map(\.target)) { _, targets in
            if let selectedTarget, !targets.contains(selectedTarget) { self.selectedTarget = nil }
        }
        .onChange(of: mailbox.presentedAccounts.map(\.account.id)) { _, ids in
            if !selectedAccount.isEmpty, !ids.contains(selectedAccount) { selectedAccount = "" }
        }
        .onChange(of: selectedTarget) { _, _ in saveError = nil }
    }

    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                Text("Account").font(.callout.bold())
                Picker("Account", selection: $selectedAccount) {
                    Label("All Accounts (Unified)", systemImage: "person.2").tag("")
                    ForEach(mailbox.presentedAccounts, id: \.account.id) { owner in
                        SenderAccountLabel(account: owner.account, address: mailbox.accountTitle(owner.account))
                            .tag(owner.account.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityIdentifier("favorites.accountPicker")
            }
            Text(selectedAccount.isEmpty ? "Choose an account to include its labels." : "All labels are included, even those hidden from the sidebar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folderList: some View {
        List(selection: $selectedTarget) {
            folderSection("Folders", options: visibleOptions.filter { !$0.isLabel })
            folderSection("Labels", options: visibleOptions.filter(\.isLabel))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.Surface.primary)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline)
        }
        .overlay {
            if visibleOptions.isEmpty {
                ContentUnavailableView(
                    mailbox.presentedAccounts.isEmpty ? "No Accounts Available" : "No Matching Folders",
                    systemImage: "folder",
                    description: Text(mailbox.presentedAccounts.isEmpty ? "Add an account to choose a favorite." : "Try another name or account.")
                )
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Folders")
        .accessibilityIdentifier("favorites.folderList")
    }

    @ViewBuilder private func folderSection(_ title: String, options: [FavoriteFolderOption]) -> some View {
        if !options.isEmpty {
            Section(title) {
                ForEach(options) { option in
                    let added = isAdded(option.target)
                    HStack(spacing: Tokens.Space.s3) {
                        Image(systemName: symbol(option))
                            .font(.body)
                            .foregroundStyle(selectedTarget == option.target ? Color.primary : color(option))
                            .frame(width: Tokens.Space.s5)
                            .accessibilityHidden(true)
                        Text(option.title).lineLimit(1)
                        Spacer(minLength: Tokens.Space.s2)
                        if added {
                            Label("Added", systemImage: "checkmark")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if selectedTarget == option.target {
                            Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, Tokens.Space.s1_5)
                    .tag(option.target)
                    .listRowSeparator(.hidden)
                    .help(option.title)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(added ? "\(option.title), already in Favorites" : option.title)
                    .accessibilityValue(added ? "Already in Favorites" : selectedTarget == option.target ? "Selected" : "")
                }
            }
        }
    }

    private func symbol(_ option: FavoriteFolderOption) -> String {
        guard let label = option.label else { return option.systemImage }
        return LabelAppearance.shared.icon(for: label)
    }

    private func color(_ option: FavoriteFolderOption) -> Color {
        if let label = option.label { return Color(gmailHex: label.backgroundColor) ?? .secondary }
        if case .mailbox(let id, _) = option.target { return SystemMailbox(labelID: id).color }
        return .secondary
    }

    private func clearSearch() { query = ""; searchFocused = true }

    private func add() async {
        guard canAdd, let selectedTarget else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        if await mailbox.navigation.addFavorite(selectedTarget) {
            onAdded()
            dismiss()
        } else {
            saveError = "Couldn't add this favorite. Try again."
        }
    }
}
