import MailStore
import SwiftUI

struct SignaturesPane: View {
    @Bindable var model: SettingsModel
    @State private var selectedAddress = ""
    @State private var signatureOnReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            SettingsGroup("Signature defaults", systemImage: "signature") {
                SettingsToggleRow("Include in replies and forwards", isOn: $signatureOnReplies)
                    .onChange(of: signatureOnReplies) { _, enabled in Task { await model.setSignatureOnReplies(enabled) } }
                Divider().padding(.horizontal, Tokens.Space.s4)
                HStack(spacing: Tokens.Space.s3) {
                    Text("From address").font(.body)
                        .fixedSize()
                    Picker("From address", selection: $selectedAddress) {
                        ForEach(model.identities, id: \.lowercasedAddress) { identity in
                            Text(identity.address + (identity.isPrimary ? " (primary)" : "")).tag(identity.address)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
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
                SettingsNote("Gmail lets Tern edit the primary address's signature. Change alias signatures in Gmail.", systemImage: "lock")
            }
            SettingsMessageEditor(draft: draft, isEditable: model.canEdit && identity.isPrimary)
            HStack {
                Spacer(minLength: 0)
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
        }
        .onChange(of: model.revision) { _, _ in
            if (draft.savedHTML ?? "") == previousHTML {
                previousHTML = identity.signatureHTML ?? ""
                draft = SettingsMessageDraft(html: identity.signatureHTML)
            }
        }
    }
}
