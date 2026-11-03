import SwiftUI

struct AssistantScopeNotice: View {
    let model: AssistantModel

    var body: some View {
        if model.hasPendingScopeChange || model.usesPreviousMailScope {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Label(model.hasPendingScopeChange ? "Mail scope changed" : "Using the previous mail scope",
                      systemImage: "envelope.badge")
                    .font(.callout.weight(.semibold))
                HStack(alignment: .top, spacing: Tokens.Space.s2) {
                    if model.conversationAccounts.count == 1, let account = model.conversationAccounts.first {
                        if let image = AccountProfileImages.shared.image(for: account.id) {
                            AvatarImage(image: image, size: Tokens.Space.s5)
                        } else {
                            TernAvatar(name: account.displayName ?? account.email, size: Tokens.Space.s5)
                        }
                    }
                    Text(model.conversationScopeDescription)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.hasPendingScopeChange {
                    Text("Your chat and unfinished message are kept. Choose the scope for your next request.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Tokens.Space.s2) { actions }
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) { actions }
                    }
                    .controlSize(.small)
                } else {
                    Button("Use current selection…", action: model.reviewCurrentScope)
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .ternOutline(radius: Tokens.Radius.md)
            .padding(.horizontal, Tokens.Space.s3)
            .padding(.top, Tokens.Space.s2)
            .frame(maxWidth: Tokens.Assistant.contentWidth)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Keep Previous Scope", action: model.keepConversationScope)
            .buttonStyle(.bordered)
        Button("Start New Chat", action: model.startChatWithCurrentScope)
            .buttonStyle(.bordered)
    }
}
