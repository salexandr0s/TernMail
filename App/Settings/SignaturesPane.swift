import MailStore
import MessageContent
import SwiftUI

struct SignaturesPane: View {
    @Bindable var model: SettingsModel
    let header: GmailSettingsHeader
    @State private var selectedAddress = ""
    @State private var signatureOnReplies = false

    var body: some View {
        SettingsPage {
            header
            Section("Sender") {
                SettingsControlRow("From address") {
                    Picker("From address", selection: $selectedAddress) {
                        ForEach(model.identities, id: \.lowercasedAddress) { identity in
                            Text(identity.address + (identity.isPrimary ? " (primary)" : "")).tag(identity.address)
                        }
                    }
                    .frame(maxWidth: Tokens.Settings.pickerWidth)
                    .help(selectedAddress)
                }
            }
            if let identity = model.identities.first(where: { $0.address == selectedAddress }) {
                SignatureEditor(identity: identity, model: model).id(identity.lowercasedAddress)
            }
            Section("Signature defaults") {
                SettingsAsyncToggleRow("Include in replies and forwards", isOn: signatureOnReplies) { enabled in
                    signatureOnReplies = enabled
                    await model.setSignatureOnReplies(enabled)
                }
            }
        }
        .task { signatureOnReplies = await model.signatureReplyPreference() }
        .onChange(of: model.identities.map(\.address), initial: true) { _, addresses in
            if !addresses.contains(selectedAddress) { selectedAddress = addresses.first ?? "" }
        }
    }
}

/// Edits save as the user types; the header's status row shows the write.
private struct SignatureEditor: View {
    let identity: IdentityRecord
    @Bindable var model: SettingsModel
    @State private var draft: SettingsMessageDraft
    /// The HTML Gmail holds, or that a queued change is about to give it.
    @State private var savedHTML: String

    init(identity: IdentityRecord, model: SettingsModel) {
        self.identity = identity
        self.model = model
        _draft = State(initialValue: SettingsMessageDraft(html: identity.signatureHTML))
        _savedHTML = State(initialValue: identity.signatureHTML ?? "")
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text(identity.address)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if isEditable {
                    Label("Changes save to Gmail as you type.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !identity.isPrimary {
                SettingsNote("Gmail lets Tern edit the primary address's signature. Change alias signatures in Gmail.", systemImage: "lock")
            }
            SettingsMessageEditor(draft: draft, isEditable: isEditable)
                .accessibilityLabel("Gmail signature")
        } header: {
            Text("Signature")
        }
        .onChange(of: draft.document) { _, _ in
            guard isEditable, (draft.savedHTML ?? "") != savedHTML else { return }
            model.liveApply.schedule { await save() }
        }
        .onChange(of: model.revision) { _, _ in
            // A refresh replaces the editor only when Gmail changed and no edit is waiting.
            let serverHTML = identity.signatureHTML ?? ""
            guard serverHTML != savedHTML, (draft.savedHTML ?? "") == savedHTML, !draft.isFocused else { return }
            savedHTML = serverHTML
            draft = SettingsMessageDraft(html: identity.signatureHTML)
        }
        .onDisappear {
            let scheduler = model.liveApply
            Task { await scheduler.flush() }
        }
    }

    private var isEditable: Bool { model.hasEditPermission && identity.isPrimary && !draft.isReadOnly }

    private func save() async {
        let html = draft.savedHTML ?? ""
        guard html != savedHTML else { return }
        if await model.saveSignature(html, previous: savedHTML, address: identity.address) {
            savedHTML = html
        }
    }
}
