import MailStore
import MessageContent
import SwiftUI

struct LocalSignaturesPane: View {
    let store: AccountStore
    let accounts: [AccountRecord]
    @State private var signatures: [LocalSignature] = []
    @State private var selectedID: String?
    @State private var name = ""
    @State private var draft = SettingsMessageDraft(html: nil)
    @State private var accountID = ""
    @State private var address = ""
    @State private var identities: [IdentityRecord] = []
    @State private var assignment = SignatureAssignment(accountID: "")
    @State private var error: String?
    @State private var loadingAssignment = false
    @State private var loadGeneration = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                Picker("Local signature", selection: $selectedID) {
                    Text("New signature").tag(String?.none)
                    ForEach(signatures) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("Signature name", text: $name)
                SettingsMessageEditor(draft: draft, isEditable: true)
                HStack {
                    Button("Delete", role: .destructive) { Task { await delete() } }.disabled(selectedID == nil)
                    Button("New") { selectedID = nil; name = ""; draft = SettingsMessageDraft(html: nil) }
                    Spacer()
                    Button("Save Signature") { Task { await save() } }
                        .buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Divider()
                Text("Signature defaults").font(.headline)
                Picker("Account", selection: $accountID) { ForEach(accounts) { Text($0.email).tag($0.id) } }
                Picker("Address", selection: $address) {
                    Text("Account default").tag("")
                    ForEach(identities, id: \.lowercasedAddress) { Text($0.address).tag($0.lowercasedAddress) }
                }
                signaturePicker("New messages", selection: $assignment.newMessages)
                signaturePicker("Replies and forwards", selection: $assignment.replies)
                Toggle("Place signature above quoted text", isOn: $assignment.placeAboveQuote)
                Toggle("Include signature separator (--)", isOn: $assignment.includeSeparator)
                Button("Save Defaults") { Task { await saveAssignment() } }.disabled(accountID.isEmpty || loadingAssignment)
                Text("Existing drafts keep the signature they already contain. An address without its own defaults uses the account default, then Gmail's signature setting.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            .padding(Tokens.Space.s4)
        }
        .task { accountID = accounts.first?.id ?? ""; await reload() }
        .task(id: accountID) { address = ""; await loadAssignment() }
        .task(id: address) { await loadAssignment() }
        .onChange(of: selectedID) { _, id in
            if let signature = signatures.first(where: { $0.id == id }) {
                name = signature.name; draft = SettingsMessageDraft(html: signature.document.html())
            } else { name = ""; draft = SettingsMessageDraft(html: nil) }
        }
    }

    private func signaturePicker(_ title: String, selection: Binding<SignatureSelection>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(SignatureSelection.none)
            Text("Gmail signature").tag(SignatureSelection.gmail)
            ForEach(signatures) { Text($0.name).tag(SignatureSelection.local(id: $0.id)) }
        }
    }
    private func reload() async {
        do { signatures = try await store.localSignatures(); await loadAssignment() }
        catch { self.error = "Couldn't load local signatures." }
    }
    private func loadAssignment() async {
        guard !accountID.isEmpty else { return }
        let requestedAccount = accountID
        let requestedAddress = address
        loadGeneration += 1
        let generation = loadGeneration
        loadingAssignment = true
        do {
            let fetchedIdentities = try await store.identities(accountID: requestedAccount).filter(\.canSend)
            let fetchedAssignment = try await store.signatureAssignments(accountID: requestedAccount).first { $0.address == requestedAddress }
                ?? SignatureAssignment(accountID: requestedAccount, address: requestedAddress)
            guard !Task.isCancelled, generation == loadGeneration, accountID == requestedAccount, address == requestedAddress else { return }
            identities = fetchedIdentities; assignment = fetchedAssignment; loadingAssignment = false
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            self.error = "Couldn't load signature defaults."; loadingAssignment = false
        }
    }
    private func save() async {
        let signature = LocalSignature(id: selectedID ?? UUID().uuidString, name: name, document: draft.document)
        do {
            try await store.saveLocalSignature(signature); await reload(); selectedID = signature.id; error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        } catch { self.error = "Couldn't save this signature." }
    }
    private func delete() async {
        guard let selectedID else { return }
        do {
            try await store.deleteLocalSignature(id: selectedID); self.selectedID = nil; await reload(); error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        } catch { self.error = "Couldn't delete this signature." }
    }
    private func saveAssignment() async {
        guard !loadingAssignment, assignment.accountID == accountID, assignment.address == address else { return }
        do {
            assignment.accountID = accountID; assignment.address = address
            try await store.saveSignatureAssignment(assignment); error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        } catch { self.error = "Couldn't save signature defaults." }
    }
}
