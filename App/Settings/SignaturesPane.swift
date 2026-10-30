import MailStore
import SwiftUI

struct SignaturesPane: View {
    @Bindable var model: SettingsModel
    @State private var selectedAddress = ""
    @State private var signatureOnReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Toggle("Include signature in replies and forwards", isOn: $signatureOnReplies)
                .onChange(of: signatureOnReplies) { _, enabled in Task { await model.setSignatureOnReplies(enabled) } }
            Picker("From address", selection: $selectedAddress) {
                ForEach(model.identities, id: \.lowercasedAddress) { identity in
                    Text(identity.address + (identity.isPrimary ? " (primary)" : "")).tag(identity.address)
                }
            }
            if let identity = model.identities.first(where: { $0.address == selectedAddress }) {
                SignatureEditor(identity: identity, model: model).id(identity.lowercasedAddress)
            }
        }
        .task { signatureOnReplies = await model.signatureReplyPreference() }
        .onChange(of: model.identities.map(\.address), initial: true) { _, addresses in
            if !addresses.contains(selectedAddress) { selectedAddress = addresses.first ?? "" }
        }
    }
}

private struct SignatureEditor: View {
    let identity: IdentityRecord
    @Bindable var model: SettingsModel
    @State private var draft: SettingsMessageDraft
    @State private var previousHTML: String

    init(identity: IdentityRecord, model: SettingsModel) {
        self.identity = identity
        self.model = model
        _draft = State(initialValue: SettingsMessageDraft(html: identity.signatureHTML))
        _previousHTML = State(initialValue: identity.signatureHTML ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            if !identity.isPrimary {
                Text("Gmail lets Tern edit the primary address's signature. Change alias signatures in Gmail.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingsMessageEditor(draft: draft, isEditable: model.canEdit && identity.isPrimary)
            Button("Save Signature") {
                let html = draft.savedHTML ?? ""
                Task {
                    if await model.saveSignature(html, previous: previousHTML, address: identity.address) {
                        previousHTML = html
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canEdit || !identity.isPrimary || draft.isReadOnly || (draft.savedHTML ?? "") == previousHTML)
        }
        .onChange(of: model.revision) { _, _ in
            if (draft.savedHTML ?? "") == previousHTML {
                previousHTML = identity.signatureHTML ?? ""
                draft = SettingsMessageDraft(html: identity.signatureHTML)
            }
        }
    }
}
