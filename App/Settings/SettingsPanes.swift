import MailStore
import SwiftUI

struct GeneralPreferencesPane: View {
    @State private var selection = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("General settings", selection: $selection) {
                Text("General").tag(0)
                Text("Mail Actions").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(Tokens.Space.s4)
            Divider()
            if selection == 0 { GeneralSettings() }
            else { TriagePreferencesPane() }
        }
    }
}

struct AccountSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var selection = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Account settings", selection: $selection) {
                Text("Connections").tag(0)
                Text("Preferences").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(Tokens.Space.s4)
            Divider()
            if selection == 0 { AccountsSettings() }
            else if let model = app.accountPreferences { AccountPreferencesView(model: model) }
            else {
                ContentUnavailableView("No accounts", systemImage: "person.crop.circle", description: Text("Add an account in Connections."))
            }
        }
    }
}

struct ComposeSettingsPane: View {
    @Environment(AppModel.self) private var app
    @State private var selection = 0
    private var accounts: [AccountRecord] {
        app.accountPreferences?.orderedRecords ?? app.mailbox?.accounts.map(\.account) ?? []
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Composing settings", selection: $selection) {
                Text("Writing").tag(0)
                Text("Templates").tag(1)
                Text("Signatures").tag(2)
                Text("Suggestions").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(Tokens.Space.s4)
            Divider()
            Group {
                if selection == 0 { ComposePreferencesPane(accounts: accounts) }
                else if let store = app.settingsAccountStore {
                    switch selection {
                    case 1: ComposeTemplatesPane(store: store)
                    case 2: LocalSignaturesPane(store: store, accounts: accounts)
                    default: SuggestionBlocklistPane(store: store, accounts: accounts)
                    }
                } else {
                    ContentUnavailableView("Settings unavailable", systemImage: "externaldrive",
                        description: Text("Open the mailbox to load saved composing settings."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
