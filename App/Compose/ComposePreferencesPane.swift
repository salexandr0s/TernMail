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
        SettingsPage {
            Section {
                SettingsControlRow("Send from") {
                    Picker("New messages from", selection: $defaultAccount) {
                        Text("Automatic").tag("")
                        ForEach(accounts) { Text($0.email).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
            } header: {
                Text("Sender")
            } footer: {
                Text("Automatic uses the selected mailbox's account. In combined mailboxes, it uses the account that last exchanged mail with the first recipient.")
            }

            Section {
                MailTextAppearancePreview(font: Font(AttributedDocument.baseFont(ComposeFont(rawValue: font) ?? .sansSerif)),
                    context: .writing)
                    .accessibilityIdentifier("settings.writing.preview")
                SettingsControlRow("Default font") {
                    Picker("Default font", selection: $font) {
                        Text("Sans serif").tag(ComposeFont.sansSerif.rawValue)
                        Text("Serif").tag(ComposeFont.serif.rawValue)
                        Text("Fixed width").tag(ComposeFont.fixedWidth.rawValue)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsToggleRow("Format Markdown", detail: "Apply formatting to typed and pasted Markdown.", isOn: $markdown)
            } header: {
                Text("Message text")
            } footer: {
                Text("The sample shows your writing font. Recipients may see a similar font if it is unavailable on their device.")
            }

            Section("Replies") {
                SettingsControlRow("Quote selected text") {
                    Picker("Quote selected text", selection: $quote) {
                        Text("Ask").tag(QuoteSelectionPolicy.ask.rawValue)
                        Text("Always").tag(QuoteSelectionPolicy.always.rawValue)
                        Text("Never").tag(QuoteSelectionPolicy.never.rawValue)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Section("Recipients") {
                SettingsToggleRow("Show full recipient addresses", isOn: $fullAddresses)
            }
        }
    }
}
