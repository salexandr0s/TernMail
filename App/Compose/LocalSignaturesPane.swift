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
        SettingsPage {
            Section("Local signatures") {
                HStack(spacing: Tokens.Space.s3) {
                    Text("Signature")
                        .frame(width: Tokens.Settings.editorLabelWidth, alignment: .leading)
                    Picker("Signature", selection: $selectedID) {
                        Text("New signature").tag(String?.none)
                        ForEach(signatures) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Button("New", systemImage: "plus") { selectedID = nil; name = ""; draft = SettingsMessageDraft(html: nil) }
                        .help("Create a new signature")
                }
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, Tokens.Space.s2)
                HStack(spacing: Tokens.Space.s3) {
                    Text("Name")
                        .frame(width: Tokens.Settings.editorLabelWidth, alignment: .leading)
                    TextField("Signature name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, Tokens.Space.s2)
                SettingsMessageEditor(draft: draft, isEditable: true)
                    .frame(minHeight: Tokens.Layout.quoteMaxHeight)
                    .padding(.horizontal, Tokens.Space.s3)
                HStack {
                    Button("Delete", role: .destructive) { Task { await delete() } }.disabled(selectedID == nil)
                    Spacer()
                    Button("Save Signature") { Task { await save() } }
                        .buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, Tokens.Space.s2)
            }

            Section("Signature defaults") {
                SettingsControlRow("Account") {
                    Picker("Account", selection: $accountID) { ForEach(accounts) { Text($0.email).tag($0.id) } }
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
                SettingsControlRow("Address") {
                    Picker("Address", selection: $address) {
                        Text("Account default").tag("")
                        ForEach(identities, id: \.lowercasedAddress) { Text($0.address).tag($0.lowercasedAddress) }
                    }
                    .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
                SettingsControlRow("New messages") {
                    signaturePicker("New messages", selection: $assignment.newMessages)
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
                SettingsControlRow("Replies and forwards") {
                    signaturePicker("Replies and forwards", selection: $assignment.replies)
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
                SettingsToggleRow("Place signature above quoted text", isOn: $assignment.placeAboveQuote)
                SettingsToggleRow("Include signature separator (--)", isOn: $assignment.includeSeparator)
                HStack {
                    if loadingAssignment { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Save Defaults") { Task { await saveAssignment() } }
                        .disabled(accountID.isEmpty || loadingAssignment)
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
            }
            SettingsNote("Existing drafts keep the signature they already contain. An address without its own defaults uses the account default, then Gmail's signature setting.")
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
