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
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("How can I help?").font(.title2.weight(.semibold))
                Text("Catch up on mail, prepare a reply, or plan your day.")
                    .foregroundStyle(.secondary)
            }
            if let setup { setupCard(setup) }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Start with your mail")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        if index > 0 {
                            Divider().padding(.leading, Tokens.Space.s3 + Tokens.Control.iconButton + Tokens.Space.s3)
                        }
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
                .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                .overlay {
                    if contrast == .increased {
                        RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                            .strokeBorder(Color.primary, lineWidth: Tokens.Border.hairline)
                            .allowsHitTesting(false)
                    }
                }
            }
            Label("Answers include sources. Review drafts in Tern before sending.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(.top, Tokens.Space.s4).padding(.bottom, Tokens.Space.s6)
    }

    private func setupCard(_ setup: AssistantSetupPrompt) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Label(setup.title, systemImage: setup.systemImage)
                .font(.callout.weight(.semibold))
            Text(setup.detail).font(.caption).foregroundStyle(.secondary)
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
        .background(Tokens.Surface.canvas, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
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
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(title).font(.callout.weight(.medium))
                        .foregroundStyle(requirement == nil ? .primary : .secondary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered && requirement == nil ? Tokens.Surface.primary : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(requirement != nil)
        .focused($isFocused)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .strokeBorder(Color.accentColor, lineWidth: Tokens.Border.focus)
                    .padding(Tokens.Space.s0_5)
                    .allowsHitTesting(false)
            }
        }
        .onHover { isHovered = $0 }
        .help(requirement ?? "Ask the assistant now")
        .accessibilityHint(requirement ?? "Ask the assistant now")
    }
}
