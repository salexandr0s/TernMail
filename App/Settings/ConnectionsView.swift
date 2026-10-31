import GmailAPI
import MailStore
import SwiftUI

/// Rows for one account's Google connections, placed inside the account's section.
/// Permanent deletion has a section of its own, `PermanentDeletionSection`.
struct ConnectionsView: View {
    let app: AppModel
    let accountID: String
    @State private var connection: SettingsAccountState
    @State private var busy = false
    @State private var error: String?

    private let features: [AccountFeature] = [.calendar, .gmailSettings, .contacts, .inboxUpdates]

    init(account: AccountRecord, app: AppModel) {
        self.app = app
        accountID = account.id
        _connection = State(initialValue: SettingsAccountState(accountID: account.id, store: app.settingsAccountStore, initial: account))
    }

    var body: some View {
        ForEach(features, id: \.rawValue) { feature in
            SettingsAsyncToggleRow(title(feature), detail: detail(feature), isOn: connection.isEnabled(feature)) { enabled in
                await set(feature, enabled: enabled)
            }
            .disabled(busy || app.isSigningIn || connection.account == nil || app.accountsNeedingSignIn.contains(accountID))
        }
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            if let state = app.inboxWatcher(for: accountID)?.state {
                Text(watcherStatus(state)).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Tokens.Status.error) }
            Text("Turning connections off stops their use in Tern. Remove Tern from your Google Account to revoke permissions.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.Space.s2) {
                if let url = URL(string: "https://myaccount.google.com/permissions") {
                    Link("Review Google Permissions", destination: url).font(.caption)
                }
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .task { await connection.observe() }
    }

    private func set(_ feature: AccountFeature, enabled: Bool) async {
        busy = true
        error = nil
        defer { busy = false }
        error = await connection.set(feature, enabled: enabled, app: app)
    }

    private func title(_ feature: AccountFeature) -> String {
        switch feature {
        case .gmailSettings: "Gmail Settings"
        case .contacts: "Contacts"
        case .inboxUpdates: "Inbox Updates"
        default: "Calendar"
        }
    }

    private func detail(_ feature: AccountFeature) -> String {
        switch feature {
        case .gmailSettings: "Edit filters, your primary signature and the vacation responder."
        case .contacts: "Suggest saved and other contacts, plus your Workspace directory when available."
        case .inboxUpdates: "Check for Inbox changes immediately. This requires Google's full mail permission."
        case .calendar: "View and edit Google Calendar events, and check availability."
        default: "Connect your Google calendars."
        }
    }

    private func watcherStatus(_ state: InboxWatcher.State) -> String {
        switch state {
        case .connecting: "Inbox Updates: connecting…"
        case .watching: "Inbox Updates: connected"
        case .unavailable(let reason): "Inbox Updates: \(reason)"
        case .stopped: "Inbox Updates: stopped"
        }
    }
}

/// Permanent deletion for every account, apart from the ordinary connections
/// because what it deletes can't be recovered.
struct PermanentDeletionSection: View {
    let accounts: [AccountRecord]
    let app: AppModel
    /// Each account's last failure, by account ID. They list below the rows,
    /// each naming its account: a grouped form crashes when a `ForEach`
    /// element adds an optional row of its own.
    @State private var errors: [String: String] = [:]

    var body: some View {
        Section {
            ForEach(accounts) { account in
                PermanentDeletionRow(account: account, app: app,
                                     error: Binding(errors[account.id], set: { errors[account.id] = $0 }))
            }
            ForEach(failures, id: \.self) { SettingsErrorLabel($0) }
        } header: {
            Text("Permanent deletion")
        } footer: {
            Label {
                Text("Lets Tern delete messages in Trash and Spam forever. They can't be recovered. This requires Google's full mail permission.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Status.warning)
                    .accessibilityHidden(true)
            }
        }
    }

    /// A line for each failed account, naming it. The lines get IDs of their
    /// own: a form shows the view of an earlier row with the same ID instead.
    private var failures: [String] {
        accounts.compactMap { account in errors[account.id].map { "\(account.email): \($0)" } }
    }
}

private struct PermanentDeletionRow: View {
    let app: AppModel
    let account: AccountRecord
    @Binding var error: String?
    @State private var connection: SettingsAccountState
    @State private var busy = false
    @State private var confirms = false

    init(account: AccountRecord, app: AppModel, error: Binding<String?>) {
        self.app = app
        self.account = account
        _error = error
        _connection = State(initialValue: SettingsAccountState(accountID: account.id, store: app.settingsAccountStore, initial: account))
    }

    var body: some View {
        let name = account.displayName.flatMap { $0.isEmpty ? nil : $0 }
        SettingsAsyncToggleRow(name ?? account.email, detail: name == nil ? nil : account.email,
                               isOn: connection.isEnabled(.permanentDeletion)) { enabled in
            if enabled { confirms = true } else { await set(enabled: false) }
        }
        .disabled(busy || app.isSigningIn || connection.account == nil || app.accountsNeedingSignIn.contains(account.id))
        .accessibilityLabel("Permanent deletion for \(account.email)")
        .task { await connection.observe() }
        .ternConfirm(
            "Allow permanent deletion for \(account.email)?",
            isPresented: $confirms,
            actionTitle: "Allow",
            message: "Tern can then delete messages from Trash and Spam for good. Google asks for its full mail permission, and deleted messages can't be recovered."
        ) {
            Task { await set(enabled: true) }
        }
    }

    private func set(enabled: Bool) async {
        busy = true
        error = nil
        defer { busy = false }
        error = await connection.set(.permanentDeletion, enabled: enabled, app: app)
    }
}

private extension SettingsAccountState {
    /// Turns a connection on or off, then reloads the account. Returns the
    /// message to show, or `nil` when the change went through.
    func set(_ feature: AccountFeature, enabled: Bool, app: AppModel) async -> String? {
        var message: String?
        do {
            if enabled {
                if let grant = try await app.enableFeature(feature, for: accountID), !grant.features.contains(feature) {
                    message = "Google didn't grant the permission this connection needs. Turn it on again to retry."
                }
            } else { try await app.disableFeature(feature, for: accountID) }
            try await refresh()
        } catch { message = "Couldn't change this connection. Try signing in again." }
        return message
    }
}
