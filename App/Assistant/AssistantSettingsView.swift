import MailStore
import SwiftUI
import TernAI

struct AssistantSettingsView: View {
    @Bindable var model: AssistantModel
    var isSheet = false
    var showsMailScope = false
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDisconnect = false
    @State private var confirmsClearChat = false
    @State private var accessChange: AccessChange?
    @State private var turningOffStyle: AssistantWritingStyleEntry?

    /// A pending access switch. Changing access clears the chat, so it waits for a yes.
    private struct AccessChange {
        let accountID: String
        let email: String
        let enabled: Bool
    }

    var body: some View {
        Group {
            if isSheet {
                SettingsEditorSheet(title: "Assistant Settings", width: Tokens.Settings.editorWideWidth,
                                    scrolls: false, onDone: { dismiss() }) {
                    Form { sections }
                        .formStyle(.grouped)
                        .frame(height: Tokens.Settings.editorMaxContentHeight)
                }
            } else {
                SettingsPage { sections }
            }
        }
        .task { await model.refreshConnection() }
        .onChange(of: model.connectionRevision) {
            model.refreshAccess()
            Task { await model.refreshConnection() }
        }
        .onChange(of: model.selectedService) { confirmsDisconnect = false }
        .ternConfirm("Disconnect from ChatGPT?", isPresented: $confirmsDisconnect, actionTitle: "Disconnect",
                     message: "Tern signs out of ChatGPT and clears the current chat.", action: disconnect)
        .ternConfirm("Clear this chat?", isPresented: $confirmsClearChat, actionTitle: "Clear Chat",
                     message: "This stops any response in progress and deletes the conversation, including unsent text.") {
            model.newChat()
        }
        .ternConfirm(accessChange.map { "\($0.enabled ? "Allow" : "Remove") assistant access to \($0.email)?" } ?? "",
                     item: $accessChange, actionTitle: accessChange?.enabled == true ? "Allow Access" : "Remove Access",
                     message: "Changing access clears the current chat.") { change in
            model.setAccountEnabled(change.accountID, enabled: change.enabled)
        }
        .ternConfirm("Turn off writing style learning?", item: $turningOffStyle, actionTitle: "Turn Off",
                     message: "Tern deletes the writing style it learned for \(turningOffStyle?.email ?? "this account"). Turning learning back on reads recent sent mail again.") { entry in
            model.writingStyle.setEnabled(entry.id, enabled: false)
        }
    }

    @ViewBuilder private var sections: some View {
        if showsMailScope {
            Section {
                SettingsControlRow("Mail scope") {
                    Picker("Mail scope", selection: $model.selectedScope) {
                        ForEach(AssistantScope.allCases) { scope in Text(scope.title).tag(scope) }
                    }
                    .frame(maxWidth: Tokens.Settings.pickerWidth)
                }
            }
        }
        providerSection
        if model.selectedService == .chatGPT {
            connectionSection
        } else {
            AssistantAPIConnectionSection(model: model)
                .id(model.selectedService)
        }
        if model.canUseAssistant { modelSection }
        accountsSection
        AssistantWritingStyleSettingsSection(model: model.writingStyle) { turningOffStyle = $0 }
        privacySection
    }

    /// Clearing the chat or changing access only needs a confirmation when there is something to lose.
    private var hasChat: Bool { !model.messages.isEmpty || !model.composerText.isEmpty }

    private var providerSection: some View {
        Section {
            SettingsControlRow("Use") {
                Picker("Assistant provider", selection: Binding(
                    get: { model.selectedService }, set: { model.selectService($0) })) {
                    ForEach(AIService.allCases) { service in
                        Text(service.displayName).tag(service)
                    }
                }
                .frame(maxWidth: Tokens.Settings.pickerWidth)
                .disabled(model.providerConnection.isConnecting || model.providerConnection.isDisconnecting)
            }
        } header: {
            Text("Provider")
        } footer: {
            Text("Changing providers clears the current chat and stops active requests. Your mail and calendar access choices apply to the selected provider.")
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack(spacing: Tokens.Space.s3) {
                ChatGPTBrand(size: Tokens.Space.s6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("ChatGPT")
                        .font(.body.weight(.medium))
                    Text(model.connection.account == nil ? "Use your ChatGPT plan in Tern." : "Connected to Tern")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.connection.account == nil, !model.connection.isConnecting, !model.connection.isDisconnecting,
                   !model.connection.isRestoring, !model.connection.needsStorageRetry {
                    ChatGPTSignInButton(action: connect)
                }
                if model.connection.account != nil, !model.connection.isConnecting, !model.connection.isDisconnecting {
                    Label(model.connection.canUsePlan ? "Plan enabled" : "Identity only",
                          systemImage: model.connection.canUsePlan ? "checkmark.circle" : "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let account = model.connection.account {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(account.name ?? account.email ?? "ChatGPT account")
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if let email = account.email, email != account.name {
                        Text(email)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if !model.connection.canUsePlan, !model.connection.isConnecting, !model.connection.isDisconnecting {
                        Text("Allow ChatGPT plan usage to use the assistant.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }

            if model.connection.isRestoring {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Opening saved connection…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if model.connection.isConnecting {
                HStack(spacing: Tokens.Space.s3) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel") { model.connection.cancelSignIn() }
                        .accessibilityLabel("Cancel ChatGPT sign-in")
                }
            } else if model.connection.isDisconnecting {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text("Disconnecting from ChatGPT…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                connectionActions
            }

            if let error = model.connection.errorMessage {
                SettingsErrorLabel(error)
            }
            if model.connection.needsStorageRetry {
                Button("Retry Keychain Access") {
                    Task {
                        await model.connection.retryStoredConnection()
                        await model.refreshConnection()
                    }
                }
                .disabled(model.connection.isRestoring || model.connection.isConnecting || model.connection.isDisconnecting)
            }
        }
    }

    @ViewBuilder private var connectionActions: some View {
        if model.connection.account != nil && !model.connection.canUsePlan {
            ChatGPTSignInButton(action: connect)
        }
        if model.connection.account == nil {
            SettingsNote("Eligible requests use your ChatGPT plan or credits.")
        }
        if model.connection.account != nil {
            HStack(spacing: Tokens.Space.s3) {
                if model.connection.canUsePlan {
                    Button("Reconnect", action: connect)
                }
                if let usageURL = URL(string: "https://chatgpt.com/settings/usage") {
                    Link(destination: usageURL) {
                        Label("Manage Usage", systemImage: "arrow.up.forward")
                    }
                    .accessibilityHint("Opens ChatGPT usage settings in your browser.")
                }
                Spacer(minLength: 0)
                Button("Disconnect…", role: .destructive) { confirmsDisconnect = true }
            }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            SettingsControlRow("Model") {
                HStack(spacing: Tokens.Space.s2) {
                    if model.isLoadingModels {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Loading \(model.providerDisplayName) models")
                    }
                    if !model.models.isEmpty {
                        Picker("Assistant model", selection: $model.selectedModelID) {
                            if model.selectedModelID.isEmpty { Text("Choose a model").tag("") }
                            ForEach(model.models) { choice in
                                Text(choice.displayName).tag(choice.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: Tokens.Settings.pickerWidth)
                        .help(model.models.first(where: { $0.id == model.selectedModelID })?.displayName ?? "Choose a model")
                        .disabled(model.isRunning || model.isLoadingModels)
                    } else {
                        Text(model.isLoadingModels ? "Loading models…" : "No models loaded")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.refreshConnection() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isRunning || model.isLoadingModels)
                    .help("Refresh available models")
                    .accessibilityLabel("Refresh available models")
                }
            }
            SettingsNote(model.selectedService == .chatGPT ? "Using ChatGPT plan" : "API usage is billed to your provider account.",
                         systemImage: "checkmark.circle")
            if let selected = model.models.first(where: { $0.id == model.selectedModelID }), !selected.supportsImages {
                SettingsNote("This model accepts text only. Remove image context files before sending.")
            }
            if let error = model.modelErrorMessage {
                SettingsErrorLabel(error)
            }
        }
    }

    private var accountsSection: some View {
        Section {
            if model.availableAccounts.isEmpty {
                Label("Add a mail account in Connections.", systemImage: "person.crop.circle.badge.plus")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.availableAccounts, id: \.id) { account in
                    accountRow(account)
                }
            }
        } header: {
            Text("Mail access")
        } footer: {
            Text("Choose the accounts the assistant can read, including automatic summaries and event suggestions when you open a permitted conversation. Changing access clears the current chat.")
        }
    }

    private func accountRow(_ account: AccountRecord) -> some View {
        let name = account.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return Toggle(isOn: Binding(model.enabledAccountIDs.contains(account.id), set: { enabled in
            if hasChat {
                accessChange = AccessChange(accountID: account.id, email: account.email, enabled: enabled)
            } else {
                model.setAccountEnabled(account.id, enabled: enabled)
            }
        })) {
            HStack(spacing: Tokens.Space.s3) {
                AddressAvatar(accountID: account.id, address: account.email, name: name ?? "", size: Tokens.Space.s6)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(name ?? account.email)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(name ?? account.email)
                    if name != nil {
                        Text(account.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(account.email)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Allow assistant access to \(account.email)")
        .accessibilityHint("Changing access clears the current chat.")
    }

    private var privacySection: some View {
        Section {
            LabeledContent {
                Button("Clear Chat…") { confirmsClearChat = true }
                    .disabled(!hasChat)
                    .accessibilityHint("Stops the current response and clears this chat.")
            } label: {
                Text("Chat history")
                Text("Cleared when Tern quits.")
            }
        } header: {
            Text("Privacy")
        } footer: {
            SettingsNote("Relevant content from enabled accounts is sent to \(dataRecipient) for your requests and automatic summaries and event suggestions in open conversations. When writing-style learning is on, sent-mail excerpts are also sent during setup. The assistant prepares drafts; you review and send them in Tern.", systemImage: "lock")
        }
    }

    private var dataRecipient: String {
        switch model.selectedService {
        case .chatGPT, .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .deepSeek: "DeepSeek"
        }
    }

    private func connect() {
        Task {
            guard model.selectedService == .chatGPT else { return }
            await model.connection.connect()
            model.refreshAccess()
            await model.refreshConnection()
        }
    }

    private func disconnect() {
        guard model.selectedService == .chatGPT else { return }
        model.stop()
        Task {
            guard model.selectedService == .chatGPT else { return }
            await model.connection.disconnect()
            model.refreshAccess()
        }
    }
}
