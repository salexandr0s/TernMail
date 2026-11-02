import SwiftUI

struct AssistantSetupPrompt {
    let title: String
    let detail: String
    let action: String
    let systemImage: String
}

struct AssistantWelcomeView: View {
    let model: AssistantModel
    let setup: AssistantSetupPrompt?
    let onSettings: () -> Void
    let onSuggestion: (AssistantSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            VStack(spacing: Tokens.Space.s3) {
                Text("How can I help?").font(.title.weight(.semibold))
                Text("Catch up on a conversation, prepare a reply, or find time to meet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            // Until setup is done, the setup card stands in for the starters,
            // which couldn't run yet.
            if let setup {
                setupCard(setup)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Layout.attachmentWidth), spacing: Tokens.Space.s2)],
                          alignment: .leading, spacing: Tokens.Space.s2) {
                    ForEach(model.suggestions) { suggestion in
                        let requirement = model.requirement(for: suggestion)
                        AssistantSuggestionRow(
                            title: model.title(for: suggestion),
                            detail: requirement ?? detail(for: suggestion),
                            systemImage: suggestion.systemImage,
                            requirement: requirement,
                            action: { onSuggestion(suggestion) }
                        )
                    }
                }
            }
            Label("Drafts and calendar changes are yours to review.", systemImage: "checkmark.shield")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(.top, Tokens.Space.s12).padding(.bottom, Tokens.Space.s6)
    }

    private func setupCard(_ setup: AssistantSetupPrompt) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Image(systemName: setup.systemImage)
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(setup.title).font(.callout.weight(.semibold))
                    Text(setup.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onSettings) {
                HStack(spacing: Tokens.Space.s2) {
                    Text(setup.action)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
    }

    private func detail(for suggestion: AssistantSuggestion) -> String {
        switch suggestion {
        case .priorities: "Open requests and upcoming deadlines"
        case .awaitingReplies: "Conversations that still need an answer"
        case .summarizeThread: "Key decisions and open tasks"
        case .draftReply: "A reply you can review and edit"
        }
    }
}

private struct AssistantSuggestionRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let requirement: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: Tokens.Space.s5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(title).font(.callout.weight(.medium))
                        .foregroundStyle(requirement == nil ? .primary : .secondary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered && requirement == nil ? Tokens.Assistant.chatBubble : Tokens.Surface.muted,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        }
        .buttonStyle(.plain).disabled(requirement != nil)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
        .onHover { isHovered = $0 }
        .help(requirement ?? "Ask the assistant now")
        .accessibilityHint(requirement ?? "Ask the assistant now")
    }
}
