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
                Picker("Account", selection: $selectedAccount) {
                    ForEach(accounts, id: \.account.id) { owner in
                        Text(owner.account.email).tag(owner.account.id)
                    }
                }
                .padding(Tokens.Space.s4)
                Divider()
                if let owner = accounts.first(where: { $0.account.id == selectedAccount }) {
                    IntegrationSettingsContent(accountID: owner.account.id, pane: pane, app: app)
                        .id(owner.account.id)
                }
            } else {
                ContentUnavailableView("No accounts", systemImage: "person.crop.circle", description: Text("Add a Google account in Accounts."))
            }
        }
        .onChange(of: app.mailbox?.accounts.map(\.account.id) ?? [], initial: true) { _, ids in
            if !ids.contains(selectedAccount) { selectedAccount = ids.first ?? "" }
        }
    }
}

private struct IntegrationSettingsContent: View {
    let pane: IntegrationSettingsPane
    @State private var model: SettingsModel
    @Environment(\.undoManager) private var undoManager

    init(accountID: String, pane: IntegrationSettingsPane, app: AppModel) {
        self.pane = pane
        _model = State(initialValue: SettingsModel(accountID: accountID, app: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                if model.isLoading { ProgressView().controlSize(.small) }
                if model.pendingCount > 0 {
                    Text("\(model.pendingCount) pending \(model.pendingCount == 1 ? "change" : "changes")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading || model.isSaving)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            if let error = model.deliveryError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }
            if let status = model.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if !model.hasEditPermission {
                Text("To save changes, turn on Gmail Settings under Accounts → Connections.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.hasLoaded {
                switch pane {
                case .signatures: SignaturesPane(model: model)
                case .filters: FiltersPane(model: model)
                case .blocked: BlockedSendersPane(model: model)
                case .vacation: VacationPane(model: model)
                }
            } else if !model.isLoading {
                ContentUnavailableView("Gmail settings unavailable", systemImage: "wifi.exclamationmark",
                    description: Text("Connect to Google and choose Refresh to load this account's settings."))
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.s4)
        .task {
            model.undoManager = undoManager
            await model.load()
            await model.watchQueue()
        }
        .task { await model.connection.observe() }
    }
}
