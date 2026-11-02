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
        VStack(alignment: .leading, spacing: Tokens.Space.s6) {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Text("Work through your mail")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Find the next reply, pull out tasks, or catch up before your next meeting.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Until setup is done, the setup card stands in for the starters,
            // which couldn't run yet.
            if let setup {
                setupCard(setup)
            } else {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    if !model.contextualSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                            Label("From your selection", systemImage: "text.badge.checkmark")
                                .font(.callout.bold())
                                .accessibilityAddTraits(.isHeader)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: Tokens.Space.s2) { selectionButtons }
                                VStack(alignment: .leading, spacing: Tokens.Space.s2) { selectionButtons }
                            }
                        }
                        .padding(Tokens.Space.s4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: .rect(cornerRadius: Tokens.Radius.lg))
                        .ternOutline(radius: Tokens.Radius.lg)
                    }
                    Text("Choose a starting point")
                        .font(.callout.bold())
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
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
            }
            Label("Drafts and calendar changes are yours to review.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(.top, Tokens.Space.s6).padding(.bottom, Tokens.Space.s6)
    }

    private var selectionButtons: some View {
        ForEach(model.contextualSuggestions) { suggestion in
            let requirement = model.requirement(for: suggestion)
            Button(suggestion == .summarizeThread ? "Summarize" : "Draft a reply", systemImage: suggestion.systemImage) {
                onSuggestion(suggestion)
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .disabled(requirement != nil)
            .help(requirement ?? model.title(for: suggestion))
        }
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
                    Text(setup.title).font(.headline)
                    Text(setup.detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onSettings) {
                HStack(spacing: Tokens.Space.s2) {
                    Text(setup.action)
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.regular)
            .disabled(model.connection.canUsePlan && model.hasAssistantDataAccess && model.isLoadingModels)
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
    }

    private func detail(for suggestion: AssistantSuggestion) -> String {
        switch suggestion {
        case .awaitingReplies: "Unanswered questions and requests, urgent first"
        case .tasksFromMail: "Open tasks and due dates, ready for your task list"
        case .eventsFromMail: "Dates, times, and events to add to Calendar"
        case .priorities: "What needs doing and when it is due"
        case .followUps: "People you are waiting to hear back from"
        case .recentMail: "Important updates and decisions from the past week"
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
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(requirement == nil ? Color.accentColor : .secondary)
                    .frame(width: Tokens.Space.s8, height: Tokens.Space.s8)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: .rect(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(title).font(.callout.bold())
                        .foregroundStyle(requirement == nil ? .primary : .secondary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, Tokens.Space.s1)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(Tokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered && requirement == nil ? Tokens.Assistant.chatBubble : Tokens.Surface.primary,
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
