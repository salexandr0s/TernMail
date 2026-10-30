import MailStore
import SwiftUI

enum IntegrationSettingsPane { case signatures, filters, blocked, vacation }

struct IntegrationSettingsView: View {
    let pane: IntegrationSettingsPane
    @Environment(AppModel.self) private var app
    @State private var selectedAccount = ""

    var body: some View {
        VStack(spacing: 0) {
            if let accounts = app.mailbox?.accounts, !accounts.isEmpty {
                if let owner = accounts.first(where: { $0.account.id == selectedAccount }) {
                    IntegrationSettingsContent(accountID: owner.account.id, pane: pane, app: app,
                        accounts: accounts.map(\.account), selectedAccount: $selectedAccount)
                        .id(owner.account.id)
                }
            } else {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("No accounts").font(.body.weight(.medium))
                    Text("Add a Google account in Accounts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(Tokens.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: Tokens.Settings.contentWidth, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: app.mailbox?.accounts.map(\.account.id) ?? [], initial: true) { _, ids in
            if !ids.contains(selectedAccount) { selectedAccount = ids.first ?? "" }
        }
    }
}

private struct IntegrationSettingsContent: View {
    let pane: IntegrationSettingsPane
    @State private var model: SettingsModel
    @Environment(\.undoManager) private var undoManager
    let accounts: [AccountRecord]
    @Binding var selectedAccount: String

    init(accountID: String, pane: IntegrationSettingsPane, app: AppModel,
         accounts: [AccountRecord], selectedAccount: Binding<String>) {
        self.pane = pane
        self.accounts = accounts
        _selectedAccount = selectedAccount
        _model = State(initialValue: SettingsModel(accountID: accountID, app: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            accountBar
            if model.isLoading && model.hasLoaded {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
                }
            } else if model.pendingCount > 0 {
                Label("\(model.pendingCount) pending \(model.pendingCount == 1 ? "change" : "changes")", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error { errorMessage(error) }
            if let error = model.deliveryError { errorMessage(error) }
            if let status = model.status { SettingsNote(status, systemImage: "checkmark.circle") }
            if !model.hasEditPermission {
                SettingsNote("To save changes, turn on Gmail Settings under Accounts → Connections.", systemImage: "lock")
            }
            if model.hasLoaded {
                paneContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if model.isLoading {
                ProgressView("Loading Gmail settings…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Gmail settings unavailable").font(.body.weight(.medium))
                    Text("Connect to Google and choose Refresh to load this account's settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(Tokens.Space.s4)
        .task {
            model.undoManager = undoManager
            await model.load()
            await model.watchQueue()
        }
        .task { await model.connection.observe() }
    }

    private var accountBar: some View {
        HStack(spacing: Tokens.Space.s3) {
            Text("Account").font(.body)
            Picker("Google account", selection: $selectedAccount) {
                ForEach(accounts) { account in
                    Text(account.email).tag(account.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Changes sync with Gmail.")
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("Refresh Gmail settings")
                .disabled(model.isLoading || model.isSaving)
        }
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .signatures:
            ScrollView {
                SignaturesPane(model: model)
            }
        case .filters: FiltersPane(model: model)
        case .blocked: BlockedSendersPane(model: model)
        case .vacation: VacationPane(model: model)
        }
    }

    private func errorMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
