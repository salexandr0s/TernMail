import MailStore
import SwiftUI

struct SuggestionBlocklistPane: View {
    let accounts: [AccountRecord]
    @State private var model: SuggestionBlocklistModel

    init(store: AccountStore, accounts: [AccountRecord]) {
        self.accounts = accounts
        _model = State(initialValue: SuggestionBlocklistModel(store: store, accountID: accounts.first?.id ?? ""))
    }

    var body: some View {
        @Bindable var model = model
        SettingsPage {
            Section {
                SettingsControlRow("Account") {
                    Picker("Account", selection: Binding(model.accountID, set: model.selectAccount)) {
                        ForEach(accounts) { Text($0.email).tag($0.id) }
                    }
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
                HStack(spacing: Tokens.Space.s2) {
                    TextField("Email address", text: $model.address)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Email address to hide")
                    Button("Hide Address") {
                        let account = model.accountID
                        let address = model.address
                        Task { await model.change(address, blocked: true, accountID: account) }
                    }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(!model.canEdit || model.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Recipient suggestions")
            } footer: {
                Text("Hidden addresses stay out of recipient suggestions for this account.")
            }

            Section("Hidden addresses") {
                if model.isLoading {
                    ProgressView("Loading hidden addresses…")
                        .controlSize(.small)
                } else if !model.hasLoaded && !model.accountID.isEmpty {
                    Button("Retry") { Task { await model.reload() } }
                } else if model.blocked.isEmpty {
                    HStack(alignment: .top, spacing: Tokens.Space.s2) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(model.accountID.isEmpty ? "No account selected" : "No hidden addresses")
                            Text(model.accountID.isEmpty
                                ? "Add a mail account in Connections to manage its recipient suggestions."
                                : "Addresses you hide will appear here. You can show them again at any time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Tokens.Space.s1)
                } else {
                    ForEach(model.blocked, id: \.self) { entry in
                        HStack(spacing: Tokens.Space.s3) {
                            Image(systemName: "envelope")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(entry)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry)
                            Spacer(minLength: Tokens.Space.s3)
                            Button("Show Again") {
                                let account = model.accountID
                                Task { await model.change(entry, blocked: false, accountID: account) }
                            }
                                .controlSize(.small)
                                .accessibilityLabel("Show \(entry) in recipient suggestions")
                                .disabled(!model.canEdit)
                        }
                        .padding(.vertical, Tokens.Space.s1)
                    }
                }
            }
            if let error = model.error { SettingsErrorLabel(error) }
        }
        .task(id: model.accountID) { await model.reload() }
        .onChange(of: accounts.map(\.id), initial: true) { _, ids in
            if !ids.contains(model.accountID) { model.selectAccount(ids.first ?? "") }
        }
    }
}

@MainActor @Observable
final class SuggestionBlocklistModel {
    private let store: AccountStore
    private(set) var accountID: String
    private(set) var blocked: [String] = []
    var address = ""
    private(set) var error: String?
    private(set) var isLoading: Bool
    private(set) var hasLoaded = false
    private(set) var isSaving = false
    private var selectionRevision = 0
    private var loadGeneration = 0

    init(store: AccountStore, accountID: String) {
        self.store = store
        self.accountID = accountID
        isLoading = !accountID.isEmpty
    }

    var canEdit: Bool { !accountID.isEmpty && hasLoaded && !isLoading && !isSaving }

    func selectAccount(_ id: String) {
        guard id != accountID else { return }
        selectionRevision += 1
        loadGeneration += 1
        accountID = id
        blocked = []
        address = ""
        error = nil
        hasLoaded = false
        isLoading = !id.isEmpty
    }

    func reload() async {
        let requestedAccount = accountID
        loadGeneration += 1
        let generation = loadGeneration
        blocked = []
        error = nil
        hasLoaded = false
        isLoading = !requestedAccount.isEmpty
        guard !requestedAccount.isEmpty else { return }
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let found = try await store.blockedSuggestionAddresses(accountID: requestedAccount).sorted()
            guard !Task.isCancelled, generation == loadGeneration, accountID == requestedAccount else { return }
            blocked = found
            hasLoaded = true
        } catch {
            guard !Task.isCancelled, generation == loadGeneration, accountID == requestedAccount else { return }
            self.error = "Couldn't load hidden suggestions."
        }
    }

    func change(_ value: String, blocked: Bool, accountID requestedAccount: String) async {
        guard requestedAccount == accountID, canEdit else { return }
        let revision = selectionRevision
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.setSuggestionBlocked(blocked, address: value, accountID: requestedAccount)
            guard accountID == requestedAccount else { return }
            if revision == selectionRevision && blocked && address == value { address = "" }
            await reload()
        } catch {
            guard revision == selectionRevision, accountID == requestedAccount else { return }
            self.error = "Enter a valid email address and try again."
        }
    }
}
