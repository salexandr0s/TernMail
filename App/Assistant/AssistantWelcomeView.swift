import SwiftUI

struct AssistantWelcomeView: View {
    let model: AssistantModel
    let onSettings: () -> Void
    let onSuggestion: (AssistantSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("How can I help?").font(.title3.weight(.semibold))
                Text("Find what needs a reply, catch up on a conversation, or prepare a draft.")
                    .foregroundStyle(.secondary)
                if !model.connection.canUsePlan {
                    Text("Connect ChatGPT, then choose the mail accounts it can read.").foregroundStyle(.secondary)
                    Button("Set up assistant", action: onSettings).buttonStyle(.borderedProminent)
                } else if model.enabledAccountIDs.isEmpty {
                    Text("Mail is shared only from accounts you enable.").foregroundStyle(.secondary)
                    Button("Choose accounts", action: onSettings).buttonStyle(.borderedProminent)
                }
            }
            VStack(spacing: Tokens.Space.s2) {
                ForEach(model.suggestions) { suggestion in
                    let requirement = model.requirement(for: suggestion)
                    Button { onSuggestion(suggestion) } label: {
                        HStack(alignment: .top, spacing: Tokens.Space.s3) {
                            Image(systemName: suggestion.systemImage)
                                .frame(width: Tokens.Space.s4).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                                Text(model.title(for: suggestion)).font(.callout.weight(.medium))
                                if let requirement {
                                    Text(requirement).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.leading)
                        .padding(Tokens.Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .ternSurface()
                    }
                    .buttonStyle(.plain).disabled(!model.canRun(suggestion))
                    .help(requirement ?? "Ask the assistant now")
                }
            }
            Text("Answers link to their sources. Drafts open in Tern for you to review and send.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Tokens.Space.s6)
    }
}
