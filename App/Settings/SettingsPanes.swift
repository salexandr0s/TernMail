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
            case .signatures: LocalSignaturesPane(store: store, accounts: accounts)
            default: SuggestionBlocklistPane(store: store, accounts: accounts)
            }
        } else {
            ContentUnavailableView("Settings Unavailable", systemImage: "externaldrive",
                description: Text("Open the mailbox to load saved composing settings."))
        }
    }
}

/// Where the Signatures pane edits. Each source keeps its own store and saves
/// the way it did as a pane of its own.
enum SignatureSource: String, CaseIterable, Identifiable, Sendable {
    case local, gmail
    var id: String { rawValue }
    /// The `UserDefaults` key holding the source the pane last showed.
    static let storageKey = "settingsSignatureSource"

    var title: String {
        switch self {
        case .local: "On This Mac"
        case .gmail: "In Gmail"
        }
    }
}

/// Signatures stored by Tern and the ones saved in Gmail, behind one source control.
struct SignaturesSettingsPane: View {
    @AppStorage(SignatureSource.storageKey) private var source = SignatureSource.local

    var body: some View {
        VStack(spacing: 0) {
            Picker("Signature source", selection: $source) {
                ForEach(SignatureSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.top, Tokens.Space.s4)
            .padding(.bottom, Tokens.Space.s2)
            switch source {
            case .local: ComposeSettingsPane(destination: .signatures)
            case .gmail: IntegrationSettingsView(pane: .signatures)
            }
        }
    }
}
