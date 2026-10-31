import MailStore
import SwiftUI

/// Pops over from the sidebar's "+" or a saved search's Edit… item.
struct SavedSearchEditor: View {
    let mailbox: MailboxModel
    let existing: SavedMailSearch?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var selectedAccount = ""
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PopupHeader(
                title: existing == nil ? "New Saved Search" : "Edit Saved Search",
                systemImage: "magnifyingglass",
                subtitle: "Search history stays off. Only this named query is saved."
            )
            Form {
                TextField("Name", text: $name)
                    .focused($isNameFocused)
                TextField("Gmail Query", text: $query)
                    .help("Use Gmail search operators such as from:, label: and has:attachment.")
                Picker("Accounts", selection: $selectedAccount) {
                    Text("All Accounts").tag("")
                    if case .accounts(let ids)? = existing?.scope, ids.count > 1 { Text("Selected Accounts").tag("__subset") }
                    ForEach(mailbox.presentedAccounts, id: \.account.id) { Text(mailbox.accountTitle($0.account)).tag($0.account.id) }
                }
                if let error = mailbox.navigation.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Tokens.Status.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.columns)
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.bottom, Tokens.Space.s5)
            PopupFooter {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: Tokens.Sheet.smallWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            name = existing?.name ?? ""
            // A new search keeps the results bar's mailbox and account scope.
            query = existing?.query ?? mailbox.search.queryText
            if case .accounts(let ids)? = existing?.scope, ids.count == 1 { selectedAccount = ids[0] }
            else if case .accounts(let ids)? = existing?.scope, ids.count > 1 { selectedAccount = "__subset" }
            else if existing == nil, let id = mailbox.search.accountID { selectedAccount = id }
            isNameFocused = true
        }
    }

    private func save() async {
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

struct SavedSearchRows: View {
    let mailbox: MailboxModel
    var body: some View {
        Section {
            ForEach(mailbox.navigation.searches) { search in
                if let target = mailbox.favoriteMailboxID(.savedSearch(id: search.id)) {
                    Label(search.name, systemImage: "magnifyingglass")
                        .tag(target)
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
            HStack {
                Text("Saved Searches")
                Spacer()
                Button { mailbox.navigation.isCreatingSearch = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("New Saved Search").accessibilityLabel("New Saved Search")
                    .popover(isPresented: Bindable(mailbox.navigation).isCreatingSearch, arrowEdge: .trailing) {
                        SavedSearchEditor(mailbox: mailbox, existing: nil)
                    }
            }
        }
    }
}
