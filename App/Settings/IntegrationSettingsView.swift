import MailStore
import SwiftUI

enum IntegrationSettingsPane { case signatures, filters, blocked, vacation }

struct IntegrationSettingsView: View {
    let pane: IntegrationSettingsPane
    @Environment(AppModel.self) private var app
    @State private var selectedAccount = ""

    var body: some View {
        // A real container: modifiers on an empty Group never fire, so the
        // first account would not be selected.
        VStack(spacing: 0) {
            if let accounts = app.mailbox?.accounts, let first = accounts.first {
                let owner = accounts.first(where: { $0.account.id == selectedAccount }) ?? first
                IntegrationSettingsContent(accountID: owner.account.id, pane: pane, app: app,
                    accounts: accounts.map(\.account), selectedAccount: $selectedAccount)
                    .id(owner.account.id)
            } else {
                ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.plus",
                                       description: Text("Add a Google account in Connections."))
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
        Group {
            if model.hasLoaded {
                paneContent
            } else {
                SettingsPage {
                    header
                    Section {
                        if model.isLoading {
                            ProgressView("Loading Gmail settings…").controlSize(.small)
                        } else {
                            LabeledContent {
                                Button("Refresh") { Task { await model.load() } }
                            } label: {
                                Text("Gmail settings unavailable")
                                Text("Connect to Google, then refresh to load this account's settings.")
                            }
                        }
                    }
                }
            }
        }
        .task {
            model.undoManager = undoManager
            await model.load()
            await model.watchQueue()
        }
        .task { await model.connection.observe() }
    }

    private var header: GmailSettingsHeader {
        GmailSettingsHeader(model: model, accounts: accounts, selectedAccount: $selectedAccount)
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .signatures: SignaturesPane(model: model, header: header)
        case .filters: FiltersPane(model: model, header: header)
        case .blocked: BlockedSendersPane(model: model, header: header)
        case .vacation: VacationPane(model: model, header: header)
        }
    }
}

/// The account picker and sync status that open every Gmail pane's form.
struct GmailSettingsHeader: View {
    @Bindable var model: SettingsModel
    let accounts: [AccountRecord]
    @Binding var selectedAccount: String

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: Tokens.Space.s2) {
                    Picker("Account", selection: $selectedAccount) {
                        ForEach(accounts) { account in
                            Text(account.email).tag(account.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: Tokens.Settings.pickerWidth)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                        .labelStyle(.iconOnly)
                        .help("Refresh Gmail settings")
                        .disabled(model.isLoading || model.isSaving)
                }
            } label: {
                Text("Account")
                Text("Changes sync with Gmail.")
            }
            activity
            if let error = model.error { errorRow(error) }
            if let error = model.deliveryError { errorRow(error) }
            if let status = model.status { SettingsNote(status, systemImage: "checkmark.circle") }
            if !model.hasEditPermission {
                SettingsNote("To save changes, turn on Gmail Settings in Connections.", systemImage: "lock")
            }
        }
    }

    @ViewBuilder private var activity: some View {
        if model.isSaving || model.liveApply.isWaiting {
            progress("Saving…")
        } else if model.isLoading && model.hasLoaded {
            progress("Refreshing…")
        } else if model.pendingCount > 0 {
            Label("\(model.pendingCount) pending \(model.pendingCount == 1 ? "change" : "changes")", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(Tokens.Status.error)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
