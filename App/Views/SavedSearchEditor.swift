import MailStore
import SwiftUI

/// A sheet for a new saved search, or a popover from a saved search's Edit…
/// item or the search results' Save button.
struct SavedSearchEditor: View {
    let mailbox: MailboxModel
    let existing: SavedMailSearch?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var selectedAccount = ""
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool

    private var canSave: Bool {
        !isSaving && !mailbox.navigation.isSaving
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        SettingsEditorSheet(
            title: existing == nil ? "New Saved Search" : "Edit Saved Search",
            width: Tokens.Settings.editorWideWidth,
            messages: mailbox.navigation.error.map { [$0] } ?? []
        ) {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        Text("Name").font(.callout.bold()).foregroundStyle(.secondary)
                        TextField("Name this search", text: $name)
                            .font(.title3.weight(.semibold))
                            .textFieldStyle(.plain)
                            .focused($isNameFocused)
                            .accessibilityLabel("Search name")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        Text("Search Query").font(.callout.bold()).foregroundStyle(.secondary)
                        TextField("Search terms or Gmail operators", text: $query, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...6)
                            .accessibilityLabel("Search query")
                            .help("Use Gmail search operators such as from:, label: and has:attachment.")
                        if let operators = URL(string: "https://support.google.com/mail/answer/7190") {
                            Link("Gmail Search Operators", destination: operators)
                                .font(.callout)
                        }
                    }
                }
                .padding(Tokens.Space.s4)
                .ternSurface(style: .grouped)

                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    Text("Search In").font(.callout.bold())
                    Picker("Accounts", selection: $selectedAccount) {
                        Text("All Accounts").tag("")
                        if case .accounts(let ids)? = existing?.scope, ids.count > 1 {
                            Text("Selected Accounts").tag("__subset")
                        }
                        ForEach(mailbox.presentedAccounts, id: \.account.id) {
                            Text(mailbox.accountTitle($0.account)).tag($0.account.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Tokens.Space.s4)
                .ternSurface(style: .grouped)

                Text("This search appears in your sidebar. Tern saves the query without keeping a search history.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(isSaving)
        } actions: {
            if isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving search") }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button("Save Search") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear(perform: loadSearch)
    }

    private func loadSearch() {
        name = existing?.name ?? ""
        // A new search keeps the results bar's mailbox and account scope.
        query = existing?.query ?? mailbox.search.queryText
        if case .accounts(let ids)? = existing?.scope, ids.count == 1 { selectedAccount = ids[0] }
        else if case .accounts(let ids)? = existing?.scope, ids.count > 1 { selectedAccount = "__subset" }
        else if existing == nil, let id = mailbox.search.accountID { selectedAccount = id }
        isNameFocused = true
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        let scope: MailSearchScope
        // Preserve an existing multi-account subset unless the picker changed it.
        if selectedAccount == "__subset", case .accounts(let ids)? = existing?.scope, ids.count > 1 { scope = .accounts(ids) }
        else { scope = selectedAccount.isEmpty ? .allAccounts : .accounts([selectedAccount]) }
        let search = SavedMailSearch(id: existing?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            scope: scope, sortOrder: existing?.sortOrder ?? mailbox.navigation.searches.count)
        if await mailbox.navigation.saveSearch(search) { dismiss() }
    }
}

/// The sidebar's saved searches. The section hides while there are none;
/// File > New Saved Search… and the search results' Save button add one.
struct SavedSearchRows: View {
    let mailbox: MailboxModel
    var body: some View {
        if !mailbox.navigation.searches.isEmpty { section }
    }

    private var section: some View {
        Section {
            ForEach(mailbox.navigation.searches) { search in
                if let target = mailbox.favoriteMailboxID(.savedSearch(id: search.id)) {
                    Label(search.name, systemImage: "magnifyingglass")
                        .lineLimit(1)
                        .help("\(search.name): \(search.query)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .sidebarHover(SidebarRowSelection(source: .savedSearch, mailbox: target))
                        .tag(SidebarRowSelection(source: .savedSearch, mailbox: target))
                        .popover(isPresented: Bindable(mailbox.navigation).searchToEdit.equals(search), arrowEdge: .trailing) {
                            SavedSearchEditor(mailbox: mailbox, existing: search)
                        }
                        .contextMenu {
                            Button("Add to Favorites") { Task { await mailbox.navigation.addFavorite(.savedSearch(id: search.id)) } }
                            Button("Edit…") { mailbox.navigation.searchToEdit = search }
                            Button("Delete", role: .destructive) { Task { await mailbox.navigation.deleteSearch(search.id) } }
                        }
                }
            }
        } header: {
            HStack(spacing: Tokens.Space.s1) {
                Text("Saved Searches")
                Spacer(minLength: Tokens.Space.s1)
                Button("New Saved Search", systemImage: "plus.circle") {
                    mailbox.navigation.isCreatingSearch = true
                }
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .buttonStyle(.borderless)
                .help("New Saved Search")
            }
            .padding(.vertical, Tokens.Space.s1_5)
        }
    }
}
