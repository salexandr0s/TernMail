import MailStore
import MessageContent
import SwiftUI

struct ComposePreferencesPane: View {
    let accounts: [AccountRecord]
    @AppStorage(ComposePreferences.fontKey) private var font = ComposeFont.sansSerif.rawValue
    @AppStorage(ComposePreferences.fullAddressesKey) private var fullAddresses = false
    @AppStorage(ComposePreferences.markdownKey) private var markdown = true
    @AppStorage(ComposePreferences.quoteKey) private var quote = QuoteSelectionPolicy.ask.rawValue
    @AppStorage(ComposePreferences.defaultAccountKey) private var defaultAccount = ""

    var body: some View {
        Form {
            Picker("Default font", selection: $font) {
                Text("Sans serif").tag(ComposeFont.sansSerif.rawValue)
                Text("Serif").tag(ComposeFont.serif.rawValue)
                Text("Fixed width").tag(ComposeFont.fixedWidth.rawValue)
            }
            Picker("New messages from", selection: $defaultAccount) {
                Text("Automatic").tag("")
                ForEach(accounts) { Text($0.email).tag($0.id) }
            }
            Text("Automatic uses the selected mailbox's account. In combined mailboxes, it uses the account that last exchanged mail with the first recipient.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Quote selected text", selection: $quote) {
                Text("Ask").tag(QuoteSelectionPolicy.ask.rawValue)
                Text("Always").tag(QuoteSelectionPolicy.always.rawValue)
                Text("Never").tag(QuoteSelectionPolicy.never.rawValue)
            }
            Toggle("Show full recipient addresses", isOn: $fullAddresses)
            Toggle("Format typed and pasted Markdown", isOn: $markdown)
        }
        .formStyle(.grouped)
    }
}
