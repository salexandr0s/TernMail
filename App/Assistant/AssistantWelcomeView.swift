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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s6) {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Label("Mail & calendar", systemImage: "sparkle")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("How can I help?").font(.title.weight(.semibold))
                Text("Catch up on a conversation, prepare a reply, or find time to meet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let setup { setupCard(setup) }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("A place to start")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Layout.attachmentWidth), spacing: Tokens.Space.s2)],
                          alignment: .leading, spacing: Tokens.Space.s2) {
                    ForEach(model.suggestions) { suggestion in
                        let requirement = model.requirement(for: suggestion)
                        AssistantSuggestionRow(
                            title: model.title(for: suggestion),
                            detail: setup == nil ? (requirement ?? detail(for: suggestion)) : detail(for: suggestion),
                            systemImage: suggestion.systemImage,
                            requirement: requirement,
                            action: { onSuggestion(suggestion) }
                        )
                    }
                }
            }
            Label("Drafts and calendar changes are yours to review.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(.top, Tokens.Space.s6).padding(.bottom, Tokens.Space.s4)
    }

    private func setupCard(_ setup: AssistantSetupPrompt) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Image(systemName: setup.systemImage)
                    .font(.title3).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(Tokens.Assistant.userBubble, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(setup.title).font(.callout.weight(.semibold))
                    Text(setup.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onSettings) {
                HStack {
                    Text(setup.action)
                    Spacer(minLength: Tokens.Space.s2)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                .strokeBorder(contrast == .increased ? Color.primary : Tokens.Surface.border,
                              lineWidth: Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
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
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(requirement == nil ? Color.accentColor : Color.secondary)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(requirement == nil ? Tokens.Assistant.userBubble : Tokens.Surface.muted,
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(title).font(.callout.weight(.medium))
                        .foregroundStyle(requirement == nil ? .primary : .secondary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isHovered && requirement == nil ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered && requirement == nil ? Tokens.Surface.muted : Tokens.Surface.primary,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        }
        .buttonStyle(.plain).disabled(requirement != nil)
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                .strokeBorder(contrast == .increased ? Color.primary : Tokens.Surface.border,
                              lineWidth: Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
        .help(requirement ?? "Ask the assistant now")
        .accessibilityHint(requirement ?? "Ask the assistant now")
    }
}
