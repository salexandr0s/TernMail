import MailStore
import MessageContent
import SwiftUI

struct LocalSignaturesPane: View {
    let store: AccountStore
    let accounts: [AccountRecord]
    @Environment(SettingsUnsavedChanges.self) private var unsaved
    @State private var baselineName = ""
    @State private var baselineDocument = ComposeDocument(plainText: "")
    @State private var baselineAssignment = SignatureAssignment(accountID: "")
    @State private var isSaving = false
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
            Section {
                ComposeLibraryPicker(title: "Saved signatures", newItemLabel: "Create a new signature",
                    symbol: "signature", identifierPrefix: "compose-signature",
                    items: signatures.map { .init(id: $0.id, name: $0.name) }, selection: guardedSignature) {
                    requestSignature(nil)
                }
            }
            Section(selectedID == nil ? "New signature" : "Edit signature") {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    TextField("Signature name", text: $name, prompt: Text("Signature name"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(Tokens.Workspace.pageTitle)
                        .padding(.horizontal, Tokens.Space.s2)
                        .padding(.top, Tokens.Space.s2)
                    SettingsMessageEditor(draft: draft, isEditable: !isSaving)
                        .frame(minHeight: Tokens.Layout.quoteMaxHeight)
                        .accessibilityLabel("Signature text")
                }
                HStack {
                    Button("Delete Signature", role: .destructive) { unsaved.request { Task { await delete() } } }.disabled(selectedID == nil)
                    Spacer()
                }
                .controlSize(.small)
            }

            Section {
                SettingsControlRow("Account") {
                    Picker("Account", selection: guardedAccount) { ForEach(accounts) { Text($0.email).tag($0.id) } }
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
                SettingsControlRow("Address") {
                    Picker("Address", selection: guardedAddress) {
                        Text("Account Default").tag("")
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
            } header: {
                Text("Signature defaults")
            } footer: {
                Text("Existing drafts keep their current signature. An address without its own defaults uses the account default, then Gmail's signature setting.")
            }
            .disabled(loadingAssignment)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SettingsFooter { saveBar } }
        .task { accountID = accounts.first?.id ?? ""; await reload() }
        .task(id: accountID) { address = ""; await loadAssignment() }
        .task(id: address) { await loadAssignment() }
        .disabled(isSaving)
        .onChange(of: hasChanges, initial: true) { _, _ in updateUnsaved() }
        .onDisappear { unsaved.clear() }
    }

    private var signatureHasChanges: Bool { name != baselineName || draft.document != baselineDocument }
    private var assignmentHasChanges: Bool { !loadingAssignment && assignment != baselineAssignment }
    private var hasChanges: Bool { signatureHasChanges || assignmentHasChanges }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if let error { SettingsErrorLabel(error) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: Tokens.Space.s4) {
                    saveSignatureAction.fixedSize()
                    Spacer(minLength: Tokens.Space.s4)
                    saveDefaultsAction.fixedSize()
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    saveSignatureAction
                    saveDefaultsAction
                }
            }
        }
    }

    private var saveSignatureAction: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(signatureHasChanges ? "Signature has unsaved changes" : "Signature text")
                .font(.caption).foregroundStyle(.secondary)
            Button("Save Signature") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var saveDefaultsAction: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(loadingAssignment ? "Loading defaults…" : assignmentHasChanges ? "Defaults have unsaved changes" : "Account defaults")
                .font(.caption).foregroundStyle(.secondary)
            Button("Save Defaults") { Task { await saveAssignment() } }
                .disabled(accountID.isEmpty || loadingAssignment)
        }
    }

    private var guardedSignature: Binding<String?> {
        Binding(get: { selectedID }, set: { id in
            guard id != selectedID else { return }
            requestSignature(id)
        })
    }
    private var guardedAccount: Binding<String> {
        Binding(get: { accountID }, set: { id in
            guard id != accountID else { return }
            if assignmentHasChanges {
                unsaved.request { accountID = id; assignment = baselineAssignment; updateUnsaved() }
            } else { accountID = id }
        })
    }
    private var guardedAddress: Binding<String> {
        Binding(get: { address }, set: { value in
            guard value != address else { return }
            if assignmentHasChanges {
                unsaved.request { address = value; assignment = baselineAssignment; updateUnsaved() }
            } else { address = value }
        })
    }

    private func requestSignature(_ id: String?) {
        if signatureHasChanges { unsaved.request { loadSignature(id) } }
        else { loadSignature(id) }
    }

    private func loadSignature(_ id: String?) {
        let signature = signatures.first { $0.id == id }
        selectedID = signature?.id
        name = signature?.name ?? ""
        draft = SettingsMessageDraft(html: signature?.document.html())
        baselineName = name
        baselineDocument = draft.document
        updateUnsaved()
    }

    private func updateUnsaved() {
        if hasChanges { unsaved.set("signature or its defaults") } else { unsaved.clear() }
    }

    private func signaturePicker(_ title: String, selection: Binding<SignatureSelection>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(SignatureSelection.none)
            Text("Gmail Signature").tag(SignatureSelection.gmail)
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
            identities = fetchedIdentities
            assignment = fetchedAssignment
            baselineAssignment = fetchedAssignment
            loadingAssignment = false
            updateUnsaved()
        } catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            self.error = "Couldn't load signature defaults."; loadingAssignment = false
        }
    }
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let signature = LocalSignature(id: selectedID ?? UUID().uuidString, name: name, document: draft.document)
        do {
            try await store.saveLocalSignature(signature)
            signatures.removeAll { $0.id == signature.id }
            signatures.append(signature)
            loadSignature(signature.id)
            error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        } catch { self.error = "Couldn't save this signature." }
    }
    private func delete() async {
        guard let selectedID, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.deleteLocalSignature(id: selectedID)
            signatures.removeAll { $0.id == selectedID }
            loadSignature(nil)
            error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        } catch { self.error = "Couldn't delete this signature." }
    }
    private func saveAssignment() async {
        guard !loadingAssignment, !isSaving, assignment.accountID == accountID, assignment.address == address else { return }
        isSaving = true
        defer { isSaving = false }
        let saved = assignment
        do {
            try await store.saveSignatureAssignment(saved)
            baselineAssignment = saved
            updateUnsaved()
            error = nil
            NotificationCenter.default.post(name: .ternComposePreferencesChanged, object: nil)
        } catch { self.error = "Couldn't save signature defaults." }
    }
}
