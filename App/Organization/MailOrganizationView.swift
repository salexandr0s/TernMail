import MailStore
import SwiftUI

struct MailOrganizationView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var sessions = app.organizationSessions
        VStack(spacing: 0) {
            if let accounts = app.mailbox?.accounts, let first = accounts.first {
                let owner = accounts.first(where: { $0.account.id == sessions.selectedAccountID }) ?? first
                if let session = sessions.session(for: owner.account.id) {
                    MailOrganizationAccountView(app: app, accountID: owner.account.id,
                        accounts: accounts.map(\.account), selectedAccount: $sessions.selectedAccountID, session: session)
                        .id(owner.account.id)
                }
            } else {
                ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.plus",
                    description: Text("Add a Google account in Connections to organize its mail."))
            }
        }
        .task {
            guard !app.assistant.composeAccessRevision.modelReady else { return }
            await app.assistant.refreshConnection()
        }
    }
}

private struct MailOrganizationAccountView: View {
    let app: AppModel
    let accountID: String
    let accounts: [AccountRecord]
    @Binding var selectedAccount: String
    let model: MailOrganizationModel
    let connection: SettingsAccountState

    init(app: AppModel, accountID: String, accounts: [AccountRecord], selectedAccount: Binding<String>,
         session: MailOrganizationSessions.Session) {
        self.app = app; self.accountID = accountID; self.accounts = accounts
        _selectedAccount = selectedAccount
        connection = session.connection
        model = session.model
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
                requirement: requirement, onOpenSettings: { SettingsNavigationRequests.shared.request($0) })
        }
        .task {
            await model.refreshDelivery()
            await model.watchDelivery()
        }
        .onChange(of: app.assistant.connection.connectionRevision) {
            Task { await app.assistant.refreshConnection() }
        }
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
