import GmailAPI
import MailStore
import SwiftUI

struct ConnectionsView: View {
    let app: AppModel
    let accountID: String
    @State private var connection: SettingsAccountState
    @State private var busy = false
    @State private var error: String?

    private let features: [AccountFeature] = [.calendar, .gmailSettings, .contacts, .inboxUpdates, .permanentDeletion]

    init(account: AccountRecord, app: AppModel) {
        self.app = app
        accountID = account.id
        _connection = State(initialValue: SettingsAccountState(accountID: account.id, store: app.settingsAccountStore, initial: account))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(features, id: \.rawValue) { feature in
                if feature != features.first {
                    Divider().padding(.horizontal, Tokens.Space.s4)
                }
                SettingsToggleRow(title(feature), detail: detail(feature), isOn: Binding(
                    get: { connection.isEnabled(feature) },
                    set: { enabled in Task { await set(feature, enabled: enabled) } }
                ))
                .disabled(busy || app.isSigningIn || connection.account == nil || app.accountsNeedingSignIn.contains(accountID))
            }
            Divider().padding(.horizontal, Tokens.Space.s4)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                if let state = app.inboxWatcher(for: accountID)?.state {
                    Text(watcherStatus(state)).font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Turning connections off stops their use in Tern. Remove Tern from your Google Account to revoke permissions.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Tokens.Space.s2) {
                    if let url = URL(string: "https://myaccount.google.com/permissions") {
                        Link("Review Google permissions", destination: url).font(.caption)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s2)
        }
        .task { await connection.observe() }
    }

    private func set(_ feature: AccountFeature, enabled: Bool) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if enabled {
                if let grant = try await app.enableFeature(feature, for: accountID), !grant.features.contains(feature) {
                    error = "Google didn't grant the permission this connection needs. Turn it on again to retry."
                }
            } else { try await app.disableFeature(feature, for: accountID) }
            try await connection.refresh()
        } catch { self.error = "Couldn't change this connection. Try signing in again." }
    }

    private func title(_ feature: AccountFeature) -> String {
        switch feature {
        case .gmailSettings: "Gmail Settings"
        case .contacts: "Contacts"
        case .inboxUpdates: "Inbox Updates"
        case .permanentDeletion: "Permanent Deletion"
        default: "Calendar"
        }
    }

    private func detail(_ feature: AccountFeature) -> String {
        switch feature {
        case .gmailSettings: "Edit filters, your primary signature and the vacation responder."
        case .contacts: "Suggest saved and other contacts, plus your Workspace directory when available."
        case .inboxUpdates: "Check for Inbox changes immediately. This requires Google's full mail permission."
        case .permanentDeletion: "Delete messages forever from Trash and Spam. This requires Google's full mail permission."
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
