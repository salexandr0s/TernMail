import SwiftUI

/// The active mail scope and model remain visible independently of unfinished input.
struct AssistantContextHeader: View {
    @Bindable var model: AssistantModel
    let onSettings: () -> Void
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s2) {
                    scopeMenu.fixedSize()
                    Spacer(minLength: Tokens.Space.s2)
                    modelMenu.fixedSize()
                    accessButton
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    HStack(spacing: Tokens.Space.s2) {
                        scopeMenu
                        Spacer(minLength: Tokens.Space.s2)
                        accessButton
                    }
                    modelMenu
                }
            }
            if !isCompact {
                Text(model.conversationScopeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(model.conversationScopeDescription)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("assistant.contextDescription")
            }
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.bottom, isCompact ? Tokens.Space.s2 : Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.primary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant context")
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Mail scope", selection: $model.selectedScope) {
                ForEach(AssistantScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Manage Mail & Calendar Access…", systemImage: "slider.horizontal.3", action: onSettings)
        } label: {
            Label(scopeTitle, systemImage: "envelope")
                .lineLimit(1)
                .frame(minHeight: Tokens.Control.iconButton)
                .contentShape(.rect(cornerRadius: Tokens.Radius.sm))
        }
        .menuIndicator(.visible).menuStyle(.borderlessButton)
        .font(.callout)
        .accessibilityLabel("Mail scope").accessibilityValue(model.conversationScopeDescription)
        .accessibilityIdentifier("assistant.scope")
        .help("Mail scope: \(model.conversationScopeDescription). Calendar access is managed separately in settings.")
    }

    private var modelMenu: some View {
        Menu {
            if model.models.isEmpty {
                Button(model.isLoadingModels ? "Loading models…" : "Choose a Model…", action: onSettings)
                    .disabled(model.isLoadingModels)
            } else {
                Picker("Model", selection: $model.selectedModelID) {
                    ForEach(model.models) { Text($0.displayName).tag($0.id) }
                }
                .pickerStyle(.inline)
                .disabled(model.isRunning || model.isLoadingModels)
            }
            Divider()
            Button("Assistant Settings…", systemImage: "gearshape", action: onSettings)
        } label: {
            Label(isCompact ? "Model" : modelName, systemImage: "sparkles")
                .lineLimit(1).truncationMode(.middle)
                .frame(minHeight: Tokens.Control.iconButton)
                .contentShape(.rect(cornerRadius: Tokens.Radius.sm))
        }
        .menuIndicator(.visible).menuStyle(.borderlessButton)
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityLabel("Model").accessibilityValue(modelName)
        .accessibilityIdentifier("assistant.model")
        .help(modelName)
    }

    private var accessButton: some View {
        Button(action: onSettings) {
            Label("Manage assistant access", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(.rect(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Manage mail and calendar access")
        .accessibilityLabel("Manage assistant access. \(model.enabledAccountIDs.count) enabled mail accounts")
        .accessibilityIdentifier("assistant.access")
    }

    private var modelName: String {
        model.models.first(where: { $0.id == model.selectedModelID })?.displayName ?? "ChatGPT"
    }

    private var scopeTitle: String {
        guard isCompact else { return model.usesPreviousMailScope ? "Previous mail scope" : model.selectedScope.title }
        if model.usesPreviousMailScope { return "Previous scope" }
        return switch model.selectedScope {
        case .selectedThreads: "Selected mail"
        case .currentAccount: "Mailbox"
        case .allEnabledAccounts: "Enabled mail"
        }
    }
}
