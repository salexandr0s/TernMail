import MailStore
import SwiftUI

struct MailOrganizationView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedAccount = ""

    var body: some View {
        VStack(spacing: 0) {
            if let accounts = app.mailbox?.accounts, let first = accounts.first {
                let owner = accounts.first(where: { $0.account.id == selectedAccount }) ?? first
                MailOrganizationAccountView(app: app, accountID: owner.account.id,
                    accounts: accounts.map(\.account), selectedAccount: $selectedAccount)
                    .id(owner.account.id)
            } else {
                ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.plus",
                    description: Text("Add a Google account in Connections to organize its mail."))
            }
        }
        .onChange(of: app.mailbox?.accounts.map(\.account.id) ?? [], initial: true) { _, ids in
            if !ids.contains(selectedAccount) { selectedAccount = ids.first ?? "" }
        }
        .task { await app.assistant.refreshConnection() }
    }
}

private struct MailOrganizationAccountView: View {
    let app: AppModel
    let accountID: String
    let accounts: [AccountRecord]
    @Binding var selectedAccount: String
    @State private var model: MailOrganizationModel
    @State private var connection: SettingsAccountState
    @AppStorage(SettingsDestination.storageKey) private var destination = SettingsDestination.organizeMail.rawValue

    init(app: AppModel, accountID: String, accounts: [AccountRecord], selectedAccount: Binding<String>) {
        self.app = app; self.accountID = accountID; self.accounts = accounts
        _selectedAccount = selectedAccount
        let connection = SettingsAccountState(accountID: accountID, store: app.settingsAccountStore,
            initial: accounts.first { $0.id == accountID })
        _connection = State(initialValue: connection)
        _model = State(initialValue: MailOrganizationBindings.make(app: app, accountID: accountID, connection: connection))
    }

    private var access: MailOrganizationAccess {
        MailOrganizationBindings.access(app: app, accountID: accountID, connection: connection)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s3) {
                Label("Google account", systemImage: "envelope")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: Tokens.Space.s2)
                Picker("Google account", selection: $selectedAccount) {
                    ForEach(accounts) { Text($0.email).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: Tokens.Settings.pickerWidth)
                .disabled(model.phase == .applying)
                .help(accounts.first { $0.id == selectedAccount }?.email ?? "")
            }
            .padding(Tokens.Space.s5)
            Divider()
            MailOrganizationExperience(model: model, canCreateFilters: access.canCreateFilters,
                requirement: requirement, onOpenSettings: { destination = $0.rawValue })
        }
        .task {
            try? await connection.refresh()
            await connection.observe()
        }
        .task { await model.watchDelivery() }
        .onChange(of: access, initial: true) { model.refreshAccess() }
        .onChange(of: app.assistant.connection.connectionRevision) {
            Task { await app.assistant.refreshConnection() }
        }
        .onDisappear { model.clear() }
    }

    private var requirement: MailOrganizationRequirement? {
        guard !access.canAnalyze else { return nil }
        if !app.assistant.connection.canUsePlan {
            return .init(message: "Connect ChatGPT to find labels that fit your mail.", destination: .assistant)
        }
        if !access.mailAccessEnabled {
            return .init(message: "Allow assistant access to this Google account to analyze its mail.", destination: .assistant)
        }
        if access.instanceID == nil {
            return .init(message: "Sign in to this Google account to read recent mail.", destination: .connections)
        }
        return .init(message: "Choose an available ChatGPT model before starting.", destination: .assistant)
    }
}
