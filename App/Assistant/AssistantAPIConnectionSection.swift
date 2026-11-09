import SwiftUI
import TernAI

/// The entry field never reads a saved key back from Keychain.
struct AssistantAPIConnectionSection: View {
    let model: AssistantModel
    @State private var apiKey = ""
    @State private var isSubmitting = false
    @State private var disconnectService: AIService?

    private var connection: AssistantProviderConnection { model.providerConnection }
    private var isBusy: Bool {
        isSubmitting || connection.isRestoring || connection.isConnecting || connection.isDisconnecting
    }

    var body: some View {
        Section("API connection") {
            LabeledContent(model.providerDisplayName) {
                if connection.canUseAssistant {
                    Label("Connected", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
            }
            SecureField(connection.canUseAssistant ? "Replacement API key" : "API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .disabled(isBusy || connection.needsStorageRetry)
                .accessibilityLabel("\(model.providerDisplayName) key")
                .accessibilityIdentifier("assistant.api-key")
                .onSubmit(connect)
            HStack(spacing: Tokens.Space.s3) {
                Button(connection.canUseAssistant ? "Validate and Replace Key" : "Validate and Connect", action: connect)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy || connection.needsStorageRetry)
                if let url = keyManagementURL {
                    Link("Manage API Keys", destination: url)
                        .accessibilityHint("Opens the provider's API key settings in your browser.")
                }
                Spacer(minLength: 0)
                if connection.canUseAssistant {
                    Button("Disconnect…", role: .destructive) { disconnectService = model.selectedService }
                        .disabled(isBusy)
                }
            }
            if isBusy {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(progressText).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = connection.errorMessage { SettingsErrorLabel(error) }
            if connection.needsStorageRetry {
                Button("Retry Keychain Access") {
                    let service = model.selectedService
                    Task {
                        guard model.selectedService == service else { return }
                        await connection.retryStoredConnection()
                        await model.refreshConnection()
                    }
                }
                .disabled(isBusy)
            }
            SettingsNote("Tern validates the key by loading available models and saves it in macOS Keychain. API usage is billed separately from a chat subscription.", systemImage: "key")
            if model.selectedService == .anthropic {
                SettingsNote("For browser sign-in with your Claude account through Claude Code, choose \(AIService.claudeCode.displayName) in Provider.")
            } else if model.selectedService == .deepSeek {
                SettingsNote("DeepSeek connects with an API key. Its public documentation does not provide an OAuth sign-in flow for Tern.")
            }
        }
        .onChange(of: model.selectedService) { apiKey = ""; disconnectService = nil }
        .onDisappear { apiKey = ""; disconnectService = nil }
        .ternConfirm("Disconnect from \(disconnectService?.displayName ?? model.providerDisplayName)?", item: $disconnectService,
                     actionTitle: "Disconnect",
                     message: "Tern removes this saved API key and clears the current chat. Revoke the key in your provider account to disable it outside Tern.",
                     action: disconnect)
    }

    private var progressText: String {
        if connection.isRestoring { return "Opening saved connection…" }
        if connection.isDisconnecting { return "Removing saved key…" }
        return "Validating API key…"
    }

    private var keyManagementURL: URL? {
        switch model.selectedService {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")
        case .chatGPT, .claudeCode: nil
        }
    }

    private func connect() {
        guard !isBusy, !connection.needsStorageRetry else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let service = model.selectedService
        apiKey = ""
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            guard model.selectedService == service else { return }
            await model.connectAPIKey(key)
        }
    }

    private func disconnect(_ service: AIService) {
        guard model.selectedService == service else { return }
        apiKey = ""
        Task {
            guard model.selectedService == service else { return }
            await model.disconnectSelectedProvider()
        }
    }
}
