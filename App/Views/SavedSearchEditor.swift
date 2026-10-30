import MailStore
import SwiftUI

struct SavedSearchEditor: View {
    let mailbox: MailboxModel
    let existing: SavedMailSearch?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var query = ""
    @State private var selectedAccount = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text(existing == nil ? "New Saved Search" : "Edit Saved Search").font(.headline)
            TextField("Name", text: $name)
            TextField("Gmail query", text: $query).help("Use Gmail search operators such as from:, label: and has:attachment.")
            Picker("Accounts", selection: $selectedAccount) {
                Text("All Accounts").tag("")
                if case .accounts(let ids)? = existing?.scope, ids.count > 1 { Text("Selected Accounts").tag("__subset") }
                ForEach(mailbox.presentedAccounts, id: \.account.id) { Text(mailbox.accountTitle($0.account)).tag($0.account.id) }
            }
            Text("Search history stays off. Only this named query is saved.").font(.caption).foregroundStyle(.secondary)
            if let error = mailbox.navigation.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Tokens.Space.s6).frame(width: Tokens.Sheet.smallWidth)
        .onAppear {
            name = existing?.name ?? ""
            query = existing?.query ?? mailbox.search.text
            if case .accounts(let ids)? = existing?.scope, ids.count == 1 { selectedAccount = ids[0] }
            else if case .accounts(let ids)? = existing?.scope, ids.count > 1 { selectedAccount = "__subset" }
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
            }
        }
    }
}
