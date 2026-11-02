import MailStore
import SwiftUI
import SyncEngine

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
            SettingsPage {
                accountSection
                analysisSection
                if let error = model.errorMessage { Section { SettingsErrorLabel(error) } }
                MailOrganizationReviewSections(model: model, canCreateFilters: access.canCreateFilters)
                if model.receipt != nil { deliverySection }
            }
            if model.phase == .review && !model.categories.isEmpty { MailOrganizationReviewFooter(model: model) }
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

    private var accountSection: some View {
        Section("Google account") {
            SettingsControlRow("Account", detail: "Labels and filters are saved in this Gmail account.") {
                Picker("Account", selection: $selectedAccount) {
                    ForEach(accounts) { Text($0.email).tag($0.id) }
                }
                .frame(maxWidth: Tokens.Settings.pickerWidth)
                .disabled(model.phase == .applying)
            }
            if !access.canAnalyze {
                SettingsNote(requirement, systemImage: "lock")
                Button("Open Assistant Settings") { destination = SettingsDestination.assistant.rawValue }
            }
            if !access.canCreateFilters {
                SettingsNote("To create filters for future incoming mail, turn on Gmail Settings in Connections. You can still apply labels to this sample.")
                Button("Open Connections") { destination = SettingsDestination.connections.rawValue }
            }
        }
    }

    private var requirement: String {
        if !app.assistant.connection.canUsePlan { return "Connect ChatGPT in Assistant Settings to analyze your mail." }
        if !access.mailAccessEnabled { return "Allow assistant access to this account in Assistant Settings." }
        if access.instanceID == nil { return "Sign in to this Google account in Connections." }
        return "Choose an available ChatGPT model in Assistant Settings."
    }

    private var analysisSection: some View {
        Section("Personalize your labels") {
            Text("Find categories that fit your mail, including recurring topics, messages that need action, and replies you're waiting for.")
                .fixedSize(horizontal: false, vertical: true)
            SettingsNote("Analyze sends the headers, short previews, and label names from your latest 250 received and sent messages combined to your connected ChatGPT account. You review the suggestions before applying them to Gmail.")
            if model.isAnalyzing {
                HStack(spacing: Tokens.Space.s3) {
                    ProgressView().controlSize(.small)
                    Text(model.phase == .reading ? "Reading recent mail…" : "Finding categories…")
                    Spacer(minLength: 0)
                    Button("Cancel") { model.clear() }
                }
            } else if model.phase == .applying {
                ProgressView("Queuing Gmail changes…").controlSize(.small)
            } else {
                Button(model.samples == nil ? "Analyze Recent Mail" : "Analyze Again", systemImage: "sparkles") {
                    model.startAnalysis()
                }
                .disabled(!model.canAnalyze)
                .accessibilityIdentifier("organization.analyze")
            }
        }
    }

    private var deliverySection: some View {
        Section("Gmail changes") {
            if let delivery = model.delivery, delivery.isComplete {
                Label("Applied to Gmail", systemImage: "checkmark.circle")
                    .foregroundStyle(Tokens.Status.success)
                SettingsNote("Your labels are available in Gmail. Enabled filters label future incoming messages from their listed senders.")
            } else if let delivery = model.delivery {
                Text("\(delivery.sentCount) delivered · \(delivery.pendingCount) pending")
                    .font(.callout)
                if delivery.failedCount > 0 {
                    SettingsErrorLabel("\(delivery.failedCount) changes failed. Open Failed Changes to review or retry them.")
                }
                if delivery.unconfirmedCount > 0 {
                    SettingsNote("Delivery of \(delivery.unconfirmedCount) changes could not be confirmed. Check the labels and filters in Gmail.",
                                 systemImage: "exclamationmark.triangle")
                }
                SettingsNote("Queued changes continue when this account is online, even after you leave this pane.")
                Button("Open Failed Changes") { destination = SettingsDestination.failedChanges.rawValue }
            } else {
                SettingsNote("Changes are queued. Checking Gmail delivery…", systemImage: "clock")
            }
            if model.phase != .complete {
                Button("Check Delivery") { Task { await model.refreshDelivery() } }
            }
        }
    }
}
