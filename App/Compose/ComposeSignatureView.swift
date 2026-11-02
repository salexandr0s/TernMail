import MessageContent
import SwiftUI

/// The outgoing signature has a preview and per-message choices. Defaults
/// remain in Settings; changing this row only changes the current draft.
struct ComposeSignatureView: View {
    @Bindable var model: ComposeModel
    let edit: () -> Void
    @State private var height = Tokens.Space.s8
    @State private var isExpanded = false

    private var html: String? { model.content.signatureHTML.flatMap { $0.isEmpty ? nil : $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Space.s2) {
                Button { isExpanded.toggle() } label: {
                    Label("Signature", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .disabled(html == nil)
                .help(isExpanded ? "Hide signature preview" : "Show signature preview")
                .accessibilityValue(html == nil ? "None" : (isExpanded ? "Expanded" : "Collapsed"))
                Spacer(minLength: Tokens.Space.s2)
                Text(html == nil ? "None" : "Included").font(.caption).foregroundStyle(.secondary)
                Menu("Change Signature", systemImage: "signature") {
                    Button("None") { model.chooseSignature(nil) }
                    if model.selectedSender?.identity.signatureHTML?.isEmpty == false {
                        Button("Gmail Signature") { model.useGmailSignature() }
                    }
                    if !model.signatures.isEmpty {
                        Divider()
                        ForEach(model.signatures) { signature in
                            Button(signature.name) { model.chooseSignature(signature) }
                        }
                    }
                    Divider()
                    Button(html == nil ? "Write Signature…" : "Edit for This Message…", action: edit)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.isEditable)
                .accessibilityIdentifier("compose-choose-signature")
            }
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.vertical, Tokens.Space.s2)
            if isExpanded, let html {
                ScrollView {
                    MessageWebView(html: MessageDocument.render(html:
                        (model.content.signatureSeparator ? "<div>-- </div>" : "") + html
                    ).html, blocker: nil, height: $height)
                        .frame(height: height)
                }
                .frame(height: min(height, Tokens.Layout.quoteMaxHeight))
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s2)
            }
        }
        .background(Tokens.Surface.muted)
        .overlay(alignment: .top) { Divider() }
        .ternAnimation(value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message signature")
    }
}
