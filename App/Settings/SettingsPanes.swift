import MailStore
import SwiftUI

/// Composing panes other than Writing read and write the settings store.
struct ComposeSettingsPane: View {
    let destination: SettingsDestination
    @Environment(AppModel.self) private var app
    private var accounts: [AccountRecord] {
        app.accountPreferences?.orderedRecords ?? app.mailbox?.accounts.map(\.account) ?? []
    }

    var body: some View {
        if destination == .writing {
            ComposePreferencesPane(accounts: accounts)
        } else if let store = app.settingsAccountStore {
            switch destination {
            case .templates: ComposeTemplatesPane(store: store)
            case .localSignatures: LocalSignaturesPane(store: store, accounts: accounts)
            default: SuggestionBlocklistPane(store: store, accounts: accounts)
            }
        } else {
            ContentUnavailableView("Settings Unavailable", systemImage: "externaldrive",
                description: Text("Open the mailbox to load saved composing settings."))
        }
    }
}
