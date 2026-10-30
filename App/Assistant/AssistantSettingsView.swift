import MailStore
import SwiftUI

struct AssistantSettingsView: View {
    @Bindable var model: AssistantModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                introduction
                connectionSection
                if model.connection.canUsePlan { modelSection }
                accountsSection
                AssistantWritingStyleSettingsSection(model: model.writingStyle)
                privacySection
            }
            .padding(Tokens.Space.s5)
        }
        .background(Tokens.Surface.canvas)
        .task { await model.refreshConnection() }
        .onChange(of: model.connection.connectionRevision) {
            model.refreshAccess()
            Task { await model.refreshConnection() }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text("Assistant")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Ask about your mail, summarize threads, and prepare replies.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(alignment: .center, spacing: Tokens.Space.s3) {
                ChatGPTBrand(size: Tokens.Space.s8)
                    .padding(Tokens.Space.s2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("ChatGPT")
                        .font(.title3.weight(.semibold))
                    Text(model.connection.account == nil ? "Use your ChatGPT plan in Tern." : "Connected to Tern")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.connection.account != nil, !model.connection.isConnecting, !model.connection.isDisconnecting {
                    TernBadge(text: model.connection.canUsePlan ? "Plan enabled" : "Identity only",
                              systemImage: model.connection.canUsePlan ? "checkmark.circle.fill" : "person.crop.circle",
                              tint: model.connection.canUsePlan ? .green : .secondary)
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

            if model.connection.isConnecting {
                HStack(spacing: Tokens.Space.s3) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel") { model.connection.cancelSignIn() }
                        .buttonStyle(.bordered)
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
                errorMessage(error)
            }
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }

    private var connectionActions: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            if model.connection.account == nil || !model.connection.canUsePlan {
                ChatGPTSignInButton(action: connect)
                if model.connection.account == nil {
                    Text("Eligible requests use your ChatGPT plan or credits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            if model.connection.account != nil {
                HStack(spacing: Tokens.Space.s3) {
                    if model.connection.canUsePlan {
                        Button("Reconnect", action: connect)
                            .buttonStyle(.bordered)
                    }
                    if let usageURL = URL(string: "https://chatgpt.com/settings/usage") {
                        Link(destination: usageURL) {
                            Label("Manage usage", systemImage: "arrow.up.forward")
                        }
                        .font(.callout)
                        .accessibilityHint("Opens ChatGPT usage settings in your browser.")
                    }
                    Spacer(minLength: 0)
                    Button("Disconnect", role: .destructive) {
                        model.stop()
                        Task {
                            await model.connection.disconnect()
                            model.refreshAccess()
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
        }
    }

    private var modelSection: some View {
        AssistantSettingsSection("Model", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                HStack(spacing: Tokens.Space.s3) {
                    if !model.models.isEmpty {
                        Picker("ChatGPT model", selection: $model.selectedModelID) {
                            if model.selectedModelID.isEmpty { Text("Choose a model").tag("") }
                            ForEach(model.models) { choice in
                                Text(choice.displayName).tag(choice.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .disabled(model.isRunning || model.isLoadingModels)
                        .accessibilityLabel("ChatGPT model")
                    } else {
                        Text(model.isLoadingModels ? "Loading models…" : "No models loaded")
                            .font(.body)
                        Spacer(minLength: 0)
                    }
                    if model.isLoadingModels {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Loading ChatGPT models")
                    }
                    Button {
                        Task { await model.refreshConnection() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRunning || model.isLoadingModels)
                    .help("Refresh available models")
                    .accessibilityLabel("Refresh available models")
                }
                Label("Using ChatGPT plan", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.modelErrorMessage {
                    errorMessage(error)
                }
            }
            .padding(Tokens.Space.s3)
        }
    }

    private var accountsSection: some View {
        AssistantSettingsSection("Mail access", systemImage: "envelope") {
            VStack(alignment: .leading, spacing: 0) {
                if model.availableAccounts.isEmpty {
                    Label("Add a mail account in Accounts settings.", systemImage: "person.crop.circle.badge.plus")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(Tokens.Space.s4)
                } else {
                    ForEach(model.availableAccounts, id: \.id) { account in
                        if account.id != model.availableAccounts.first?.id {
                            Divider()
                                .padding(.leading, Tokens.Control.avatar + Tokens.Space.s3 * 2)
                        }
                        accountRow(account)
                    }
                }
                Divider()
                Text("Choose the accounts the assistant can read. Changing access clears the current chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Tokens.Space.s3)
            }
        }
    }

    private func accountRow(_ account: AccountRecord) -> some View {
        let name = account.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: Tokens.Space.s3) {
            TernAvatar(name: name ?? account.email)
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
            Spacer(minLength: Tokens.Space.s2)
            Toggle("Allow assistant access", isOn: Binding(
                get: { model.enabledAccountIDs.contains(account.id) },
                set: { model.setAccountEnabled(account.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .fixedSize()
            .accessibilityLabel("Allow assistant access to \(account.email)")
            .accessibilityHint("Changing access clears the current chat.")
        }
        .padding(Tokens.Space.s3)
    }

    private var privacySection: some View {
        AssistantSettingsSection("Privacy", systemImage: "lock") {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Text("Relevant mail and attachment text from enabled accounts can be sent to OpenAI for your requests. When writing-style learning is on, sent-mail excerpts are also sent during setup. The assistant prepares drafts; you review and send them in Tern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack(spacing: Tokens.Space.s3) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text("Chat history")
                            .font(.body.weight(.medium))
                        Text("Cleared when Tern quits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Clear chat") { model.newChat() }
                        .buttonStyle(.bordered)
                        .disabled(model.messages.isEmpty && model.composerText.isEmpty)
                        .accessibilityHint("Stops the current response and clears this chat.")
                }
            }
            .padding(Tokens.Space.s3)
        }
    }

    private func errorMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel("\(message)")
    }

    private func connect() {
        Task {
            await model.connection.connect()
            model.refreshAccess()
            await model.refreshConnection()
        }
    }
}

private struct AssistantSettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Space.s1)
                .accessibilityAddTraits(.isHeader)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .ternSurface()
        }
    }
}
