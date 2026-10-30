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
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Picker("Account", selection: $accountID) { ForEach(accounts) { Text($0.email).tag($0.id) } }
            Text("Hidden addresses stay out of recipient suggestions for this account.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Email address", text: $address)
                Button("Hide") { Task { await change(address, blocked: true) } }.disabled(accountID.isEmpty || address.isEmpty)
            }
            List(blocked, id: \.self) { entry in
                HStack {
                    Text(entry).textSelection(.enabled)
                    Spacer()
                    Button("Show Again") { Task { await change(entry, blocked: false) } }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .padding(Tokens.Space.s4)
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
