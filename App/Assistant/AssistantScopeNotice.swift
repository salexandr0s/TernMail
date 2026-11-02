import SwiftUI

struct AssistantScopeNotice: View {
    let model: AssistantModel
    var detailsMaxHeight: CGFloat? = nil

    var body: some View {
        if model.hasPendingScopeChange || model.usesPreviousMailScope {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text(model.hasPendingScopeChange ? "Mail scope changed" : "Using the previous mail scope")
                    .font(.callout.weight(.semibold))
                if let detailsMaxHeight {
                    ScrollView {
                        details.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: detailsMaxHeight)
                    .accessibilityIdentifier("assistant.scopeDetails")
                } else {
                    details
                }
                if model.hasPendingScopeChange {
                    ViewThatFits(in: .horizontal) {
                        HStack { actions }
                        VStack(alignment: .leading) { actions }
                    }
                } else {
                    Button("Use current selection…", action: model.reviewCurrentScope)
                        .buttonStyle(.link).font(.caption)
                        .accessibilityIdentifier("assistant.scope.reviewCurrent")
                }
            }
            .padding(detailsMaxHeight == nil ? Tokens.Space.s3 : Tokens.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surface.muted)
            .accessibilityElement(children: .contain)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(model.conversationScopeDescription)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.hasPendingScopeChange {
                Text("Your chat and unfinished message are kept. Choose the scope for your next request.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Keep Previous Scope", action: model.keepConversationScope)
            .fixedSize().accessibilityIdentifier("assistant.scope.keepPrevious")
        Button("Start New Chat", action: model.startChatWithCurrentScope)
            .fixedSize().accessibilityIdentifier("assistant.scope.startNewChat")
    }
}
