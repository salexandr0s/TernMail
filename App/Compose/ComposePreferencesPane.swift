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
            SettingsGroup("New messages", systemImage: "envelope") {
                SettingsControlRow("Send from") {
                    Picker("New messages from", selection: $defaultAccount) {
                        Text("Automatic").tag("")
                        ForEach(accounts) { Text($0.email).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
                SettingsNote("Automatic uses the selected mailbox's account. In combined mailboxes, it uses the account that last exchanged mail with the first recipient.")
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.bottom, Tokens.Space.s2)
            }

            SettingsGroup("Writing", systemImage: "textformat") {
                SettingsControlRow("Default font") {
                    Picker("Default font", selection: $font) {
                        Text("Sans serif").tag(ComposeFont.sansSerif.rawValue)
                        Text("Serif").tag(ComposeFont.serif.rawValue)
                        Text("Fixed width").tag(ComposeFont.fixedWidth.rawValue)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Format Markdown", detail: "Apply formatting to typed and pasted Markdown.", isOn: $markdown)
            }

            SettingsGroup("Replies and recipients", systemImage: "arrowshape.turn.up.left") {
                SettingsControlRow("Quote selected text") {
                    Picker("Quote selected text", selection: $quote) {
                        Text("Ask").tag(QuoteSelectionPolicy.ask.rawValue)
                        Text("Always").tag(QuoteSelectionPolicy.always.rawValue)
                        Text("Never").tag(QuoteSelectionPolicy.never.rawValue)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().padding(.horizontal, Tokens.Space.s4)
                SettingsToggleRow("Show full recipient addresses", isOn: $fullAddresses)
            }
        }
    }
}
