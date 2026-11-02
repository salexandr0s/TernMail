import MailStore
import SwiftUI

struct SuggestionBlocklistPane: View {
    let store: AccountStore
    let accounts: [AccountRecord]
    @State private var accountID = ""
    @State private var blocked: [String] = []
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        SettingsPage {
            Section {
                SettingsControlRow("Account") {
                    Picker("Account", selection: $accountID) {
                        ForEach(accounts) { Text($0.email).tag($0.id) }
                    }
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                        .disabled(accounts.isEmpty)
                }
                if let error { SettingsErrorLabel(error) }
            } header: {
                Text("Recipient suggestions")
            } footer: {
                Text("Hide addresses from suggestions for this account. This does not block incoming mail.")
            }
            Section {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    TextField("Email address", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .disabled(accountID.isEmpty)
                        .accessibilityLabel("Email address to hide")
                    HStack {
                        Spacer(minLength: 0)
                        Button("Hide Address") { Task { await change(address, blocked: true) } }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                            .disabled(accountID.isEmpty || address.isEmpty)
                    }
                }
            } header: {
                Text("Hide a recipient")
            } footer: {
                Text("You can still enter hidden addresses manually when writing a message.")
            }

            Section {
                if blocked.isEmpty {
                    HStack(alignment: .top, spacing: Tokens.Space.s2) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(accountID.isEmpty ? "No account selected" : "No hidden addresses")
                            Text(accountID.isEmpty
                                ? "Add a mail account in Connections to manage its recipient suggestions."
                                : "Addresses you hide will appear here. You can show them again at any time.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Tokens.Space.s1)
                } else {
                    ForEach(blocked, id: \.self) { entry in
                        HStack(spacing: Tokens.Space.s3) {
                            Image(systemName: "envelope")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(entry).font(.body.weight(.medium))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry)
                            Spacer(minLength: Tokens.Space.s3)
                            Button("Show Again") { Task { await change(entry, blocked: false) } }
                                .fixedSize()
                                .accessibilityLabel("Show \(entry) in recipient suggestions")
                                .help("Include this address in recipient suggestions again")
                        }
                        .padding(.vertical, Tokens.Space.s1)
                    }
                }
            } header: {
                HStack(spacing: Tokens.Space.s2) {
                    Text("Hidden addresses")
                    Text("\(blocked.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .task { accountID = accounts.first?.id ?? ""; await reload() }
        .task(id: accountID) { await reload() }
    }

    private func reload() async {
        guard !accountID.isEmpty else { blocked = []; return }
        let requestedAccount = accountID
        do {
            let found = try await store.blockedSuggestionAddresses(accountID: requestedAccount).sorted()
            guard !Task.isCancelled, accountID == requestedAccount else { return }
            blocked = found
        } catch {
            guard !Task.isCancelled, accountID == requestedAccount else { return }
            self.error = "Couldn't load hidden suggestions."
        }
    }
    private func change(_ value: String, blocked: Bool) async {
        do {
            try await store.setSuggestionBlocked(blocked, address: value, accountID: accountID)
            address = ""; error = nil; await reload()
        } catch { self.error = "Enter a valid email address and try again." }
    }
}
