import SwiftUI

struct OnboardingChatGPTStep: View {
    @Environment(AppModel.self) private var app
    private var model: AssistantModel { app.assistant }
    private var connection: ChatGPTConnection { model.connection }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                HStack(spacing: Tokens.Space.s4) {
                    ChatGPTBrand(size: Tokens.Space.s10).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        HStack(spacing: Tokens.Space.s2) {
                            Text("ChatGPT in Tern").font(.headline)
                            if !connection.canUsePlan { TernBadge(text: "Optional") }
                        }
                        Text("Get summaries, find mail, and work on replies.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                connectionContent
            }
            .padding(Tokens.Space.s5)
            .ternSurface()

            if let error = connection.errorMessage { OnboardingError(message: error) }
            if connection.needsStorageRetry {
                Button("Retry Keychain access") {
                    Task {
                        await connection.retryStoredConnection()
                        await model.refreshConnection()
                    }
                }
                .disabled(isBusy)
            }
            if connection.canUsePlan { mailAccess }
            if !OnboardingPreview.allowsChatGPTSignIn {
                OnboardingNote(text: "ChatGPT sign-in is disabled in this preview.", symbol: "info.circle")
            }
            OnboardingNote(text: "ChatGPT is optional. Eligible requests use your ChatGPT plan or credits. You can connect later in Settings.", symbol: "info.circle")
        }
        .task { await model.refreshConnection() }
    }

    private var isBusy: Bool { connection.isConnecting || connection.isRestoring || connection.isDisconnecting }

    @ViewBuilder private var connectionContent: some View {
        if connection.isRestoring {
            progress("Opening your saved connection…")
        } else if connection.isConnecting {
            HStack(spacing: Tokens.Space.s3) {
                progress("Finish signing in in your browser.")
                Spacer(minLength: 0)
                Button("Cancel") { connection.cancelSignIn() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel ChatGPT sign-in")
            }
        } else if connection.isDisconnecting {
            progress("Disconnecting from ChatGPT…")
        } else if connection.canUsePlan, let account = connection.account {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Status.success)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("ChatGPT connected").font(.body.weight(.semibold))
                    Text(account.email ?? account.name ?? "Your ChatGPT account")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
            }
        } else if !connection.needsStorageRetry {
            if connection.account != nil {
                Text("You're signed in. Allow ChatGPT plan usage to enable the assistant.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ChatGPTSignInButton {
                guard OnboardingPreview.allowsChatGPTSignIn else { return }
                Task {
                    await connection.connect()
                    model.refreshAccess()
                    await model.refreshConnection()
                }
            }
            .disabled(!OnboardingPreview.allowsChatGPTSignIn)
            .accessibilityIdentifier("onboarding.connectChatGPT")
        }
    }

    private var mailAccess: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Text("Choose which mail ChatGPT can use").font(.body.weight(.semibold))
            Text("Relevant content from these accounts is sent to OpenAI for your requests, summaries, and event suggestions. You review and send every reply.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(model.availableAccounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().padding(.leading, Tokens.Space.s4) }
                    Toggle(isOn: Binding(model.enabledAccountIDs.contains(account.id), set: {
                        model.setAccountEnabled(account.id, enabled: $0)
                    })) {
                        Text(account.email).lineLimit(1).truncationMode(.middle).help(account.email)
                    }
                    .toggleStyle(.switch)
                    .padding(Tokens.Space.s4)
                    .accessibilityLabel("Allow ChatGPT to use mail from \(account.email)")
                }
            }
            .ternSurface()
            if let error = model.modelErrorMessage {
                OnboardingError(message: error)
                Button("Retry loading models") { Task { await model.refreshConnection() } }
                    .disabled(model.isLoadingModels)
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
