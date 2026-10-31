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
            SettingsGroup("Recipient suggestions", systemImage: "person.crop.circle.badge.checkmark") {
                SettingsControlRow("Account") {
                    Picker("Account", selection: $accountID) { ForEach(accounts) { Text($0.email).tag($0.id) } }
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
                Divider().padding(.horizontal, Tokens.Space.s4)
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    HStack(spacing: Tokens.Space.s2) {
                        TextField("Email address", text: $address)
                            .textFieldStyle(.roundedBorder)
                        Button("Hide Address") { Task { await change(address, blocked: true) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(accountID.isEmpty || address.isEmpty)
                    }
                    Text("Hidden addresses stay out of recipient suggestions for this account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
            }

            SettingsGroup("Hidden addresses", systemImage: "eye.slash") {
                if blocked.isEmpty {
                    HStack(alignment: .top, spacing: Tokens.Space.s2) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(accountID.isEmpty ? "No account selected" : "No hidden addresses")
                            Text(accountID.isEmpty
                                ? "Add a mail account in Accounts settings to manage its recipient suggestions."
                                : "Addresses you hide will appear here. You can show them again at any time.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Space.s4)
                    .padding(.vertical, Tokens.Space.s3)
                } else {
                    ForEach(blocked, id: \.self) { entry in
                        if entry != blocked.first { Divider().padding(.horizontal, Tokens.Space.s4) }
                        HStack(spacing: Tokens.Space.s3) {
                            Image(systemName: "envelope")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(entry)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry)
                            Spacer(minLength: Tokens.Space.s3)
                            Button("Show Again") { Task { await change(entry, blocked: false) } }
                                .controlSize(.small)
                                .accessibilityLabel("Show \(entry) in recipient suggestions")
                        }
                        .padding(.horizontal, Tokens.Space.s4)
                        .padding(.vertical, Tokens.Space.s2)
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
