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
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(title: "Add Favorite", systemImage: "star", subtitle: "Keep a folder within reach in your sidebar.")
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                accountPicker
                HStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a folder", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityIdentifier("favorites.searchFolders")
                    if !query.isEmpty {
                        Button {
                            query = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear folder search")
                    }
                }
                .padding(Tokens.Space.s2)
                .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(searchFocused ? Color.accentColor : Tokens.Surface.border,
                                      lineWidth: searchFocused ? Tokens.Border.focus : Tokens.Border.hairline)
                }
                folderList
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Tokens.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("favorites.saveError")
                } else {
                    Text(selectedAccount.isEmpty ? "Choose an account to see its labels." : "Hidden labels are included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.bottom, Tokens.Space.s4)
            .disabled(isSaving)
            PopupFooter {
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Add Favorite") { Task { await add() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
                    .accessibilityIdentifier("favorites.confirmAdd")
            }
        }
        .frame(width: Tokens.Settings.editorWidth)
        .fixedSize(horizontal: false, vertical: true)
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
        HStack(spacing: Tokens.Space.s3) {
            Text("Account").font(.callout).foregroundStyle(.secondary)
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
                VStack(spacing: Tokens.Space.s2) {
                    Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                    Text(mailbox.presentedAccounts.isEmpty ? "No accounts available" : "No matching folders")
                        .font(.headline)
                    Text(mailbox.presentedAccounts.isEmpty ? "Add an account to choose a favorite." : "Try another name or account.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(Tokens.Space.s5)
            }
        }
        .frame(height: Tokens.Layout.sidebarWidth)
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
