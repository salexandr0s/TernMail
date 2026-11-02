import SwiftUI

/// The proposed wording is separate from the transcript and the existing draft.
struct ComposeAssistantProposalView: View {
    let proposal: ComposeAssistantProposal
    let preservesInlineImages: Bool
    let statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Suggested draft", systemImage: "doc.text")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Compose.gutter)
                .padding(.vertical, Tokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Surface.muted)
            Divider()
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Subject").font(.caption).foregroundStyle(.secondary)
                Text(proposal.subject.isEmpty ? "No Subject" : proposal.subject)
                    .font(Tokens.Workspace.pageTitle)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Tokens.Compose.gutter)
            Divider()
            Text(proposal.body)
                .font(.body)
                .lineSpacing(Tokens.Space.s0_5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Compose.gutter)
            if preservesInlineImages || statusMessage != nil {
                Divider()
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    if preservesInlineImages {
                        Label("Inline images will stay below the rewritten text.", systemImage: "photo")
                    }
                    if let statusMessage {
                        Label(statusMessage, systemImage: "info.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Tokens.Space.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.primary)
        .clipShape(.rect(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
        .accessibilityIdentifier("compose-assistant-preview")
    }
}
