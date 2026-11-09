import SwiftUI
import TernAI

struct AssistantClaudeCLIConnectionSection: View {
    let model: AssistantModel
    @State private var disconnectService: AIService?
    @State private var loginCode = ""

    private var connection: ClaudeCLIConnection { model.providerConnection.claudeCLI }
    private var isBusy: Bool { connection.isRestoring || connection.isConnecting || connection.isDisconnecting }

    var body: some View {
        Section("Claude connection") {
            LabeledContent("Claude") {
                if connection.isConnected {
                    Label("Connected", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
            }
            if connection.status?.loggedIn == true {
                LabeledContent("Account", value: connection.authenticationLabel)
            }
            if connection.status?.available == false {
                SettingsNote("Install Claude Code on this Mac to connect your Claude account.", systemImage: "terminal")
                HStack(spacing: Tokens.Space.s3) {
                    installationLink
                    Button("Check Again", action: checkInstallation)
                        .disabled(isBusy)
                }
            } else {
                connectionActions
            }
            if isBusy {
                HStack(spacing: Tokens.Space.s3) {
                    ProgressView().controlSize(.small)
                    Text(progressText).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if connection.isConnecting {
                        Button("Cancel") {
                            loginCode = ""
                            connection.cancelSignIn()
                            model.refreshAccess()
                        }
                        .accessibilityLabel("Cancel Claude connection")
                    }
                }
            }
            if connection.isConnecting, let url = connection.signInURL {
                Link("Open Sign-In Page", destination: url)
                if connection.canSubmitLoginCode {
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        SettingsNote("If the browser gives you a sign-in code, paste it here.")
                        SecureField("Sign-in code", text: $loginCode)
                            .textFieldStyle(.roundedBorder)
                            .disabled(connection.isSubmittingCode)
                            .onSubmit(submitLoginCode)
                            .accessibilityIdentifier("assistant.claude-cli.sign-in-code")
                        Button("Continue Sign-In", action: submitLoginCode)
                            .disabled(loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || connection.isSubmittingCode)
                    }
                }
            }
            if let error = connection.errorMessage { SettingsErrorLabel(error) }
            SettingsNote("Runs your installed Claude Code using its signed-in account. Sign In opens its browser sign-in and may change the account used by Claude Code.", systemImage: "terminal")
            SettingsNote("Requests use the signed-in account's subscription limits or API billing. Disconnecting stops Tern from using this connection and leaves Claude Code signed in.", systemImage: "person.crop.circle")
        }
        .onChange(of: model.selectedService) { disconnectService = nil; loginCode = "" }
        .onChange(of: connection.canSubmitLoginCode) { if !connection.canSubmitLoginCode { loginCode = "" } }
        .onDisappear { disconnectService = nil; loginCode = "" }
        .ternConfirm("Disconnect from Claude?", item: $disconnectService, actionTitle: "Disconnect",
                     message: "Tern clears the current chat and stops using this connection. Claude Code stays signed in.",
                     action: disconnect)
    }

    private var connectionActions: some View {
        HStack(spacing: Tokens.Space.s3) {
            Button(connection.isConnected ? "Check Connection" : "Connect Claude Code", action: connect)
                .disabled(isBusy)
                .accessibilityIdentifier("assistant.claude-cli.connect")
            Button("Sign In…", action: signIn)
                .disabled(isBusy)
                .accessibilityHint("Opens Claude Code's browser sign-in.")
                .accessibilityIdentifier("assistant.claude-cli.sign-in")
            Spacer(minLength: 0)
            if connection.isConnected {
                Button("Disconnect…", role: .destructive) { disconnectService = model.selectedService }
                    .disabled(isBusy)
            }
        }
    }

    @ViewBuilder private var installationLink: some View {
        if let url = URL(string: "https://code.claude.com/docs/en/setup#install-claude-code") {
            Link("Install Claude Code", destination: url)
                .accessibilityHint("Opens Anthropic's installation instructions in your browser.")
        }
    }

    private var progressText: String {
        if connection.isRestoring { return "Checking Claude Code…" }
        if connection.isDisconnecting { return "Disconnecting…" }
        return "Connecting to Claude. Finish signing in if your browser opens."
    }

    private func connect() {
        Task {
            guard model.selectedService == .claudeCode else { return }
            await model.connectClaudeCLI()
        }
    }

    private func signIn() {
        Task {
            guard model.selectedService == .claudeCode else { return }
            await model.signInClaudeCLI()
        }
    }

    private func submitLoginCode() {
        guard connection.canSubmitLoginCode, !connection.isSubmittingCode else { return }
        let code = loginCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        let revision = connection.connectionRevision
        loginCode = ""
        Task {
            guard model.selectedService == .claudeCode, connection.connectionRevision == revision,
                  connection.canSubmitLoginCode else { return }
            await connection.submitLoginCode(code)
        }
    }

    private func checkInstallation() {
        Task {
            guard model.selectedService == .claudeCode else { return }
            await connection.checkAvailability()
            model.refreshAccess()
        }
    }

    private func disconnect(_ service: AIService) {
        guard service == .claudeCode, model.selectedService == service else { return }
        Task {
            guard model.selectedService == service else { return }
            await model.disconnectSelectedProvider()
        }
    }
}
