import SwiftUI

struct AssistantScopeNotice: View {
    let model: AssistantModel

    var body: some View {
        if model.hasPendingScopeChange || model.usesPreviousMailScope {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text(model.hasPendingScopeChange ? "Mail scope changed" : "Using the previous mail scope")
                    .font(.callout.weight(.semibold))
                Text(model.conversationScopeDescription)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.hasPendingScopeChange {
                    Text("Your chat and unfinished message are kept. Choose the scope for your next request.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack { actions }
                        VStack(alignment: .leading) { actions }
                    }
                } else {
                    Button("Use current selection…", action: model.reviewCurrentScope)
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(Tokens.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Surface.muted)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Keep Previous Scope", action: model.keepConversationScope)
        Button("Start New Chat", action: model.startChatWithCurrentScope)
    }
}
