import SwiftUI

struct AssistantSettingsView: View {
    @Bindable var model: AssistantModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                connectionSection
                if model.connection.canUsePlan { modelSection }
                accountsSection
                historySection
            }
            .padding(Tokens.Space.s4)
        }
        .background(Tokens.Surface.canvas)
        .task { await model.refreshConnection() }
        .onChange(of: model.connection.connectionRevision) {
            model.refreshAccess()
            Task { await model.refreshConnection() }
        }
    }

    private var connectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                if let account = model.connection.account {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(account.name ?? account.email ?? "ChatGPT account")
                            .font(.headline)
                        if let email = account.email, email != account.name {
                            Text(email).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(model.connection.canUsePlan ? "ChatGPT plan usage is enabled." : "ChatGPT plan usage is not enabled.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                } else {
                    Text("Use your ChatGPT plan for the assistant.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if model.connection.isConnecting {
                    HStack(spacing: Tokens.Space.s2) {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser.").font(.callout)
                        Spacer()
                        Button("Cancel") { model.connection.cancelSignIn() }
                    }
                } else {
                    connectionActions
                }

                if let error = model.connection.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s2)
        } label: {
            Label("ChatGPT", systemImage: "person.crop.circle")
        }
    }

    private var connectionActions: some View {
        HStack(spacing: Tokens.Space.s3) {
            if model.connection.account == nil {
                Button("Continue with ChatGPT") { connect() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(model.connection.canUsePlan ? "Reconnect" : "Enable ChatGPT plan usage") { connect() }
                Spacer(minLength: Tokens.Space.s2)
                Button("Disconnect") {
                    model.stop()
                    Task {
                        await model.connection.disconnect()
                        model.refreshAccess()
                    }
                }
            }
            if let usageURL = URL(string: "https://chatgpt.com/settings/usage") {
                Link("Manage usage", destination: usageURL)
                    .font(.callout)
            }
        }
        .disabled(model.connection.isDisconnecting)
    }

    private var modelSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                if !model.models.isEmpty {
                    Picker("Model", selection: $model.selectedModelID) {
                        if model.selectedModelID.isEmpty { Text("Choose a model").tag("") }
                        ForEach(model.models) { choice in
                            Text(choice.displayName).tag(choice.id)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Text("Load the models available to your ChatGPT account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh models") { Task { await model.refreshConnection() } }
                    .disabled(model.isRunning)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s2)
        } label: {
            Label("Model", systemImage: "slider.horizontal.3")
        }
    }

    private var accountsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Text("When you ask, relevant mail and attachment text from enabled accounts can be sent to OpenAI. The assistant can prepare drafts; you send them from Tern.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.availableAccounts.isEmpty {
                    Text("Add a mail account in Accounts settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.availableAccounts, id: \.id) { account in
                    Toggle(isOn: Binding(
                        get: { model.enabledAccountIDs.contains(account.id) },
                        set: { model.setAccountEnabled(account.id, enabled: $0) }
                    )) {
                        Text(account.email)
                            .lineLimit(1)
                            .help(account.email)
                    }
                    .toggleStyle(.switch)
                    .accessibilityLabel("Allow assistant access to \(account.email)")
                }
                Text("Changing access clears the current chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s2)
        } label: {
            Label("Mail access", systemImage: "envelope")
        }
    }

    private var historySection: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Text("Chat history stays in memory until Tern quits.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Clear chat") { model.newChat() }
                .disabled(model.messages.isEmpty && model.composerText.isEmpty)
        }
    }

    private func connect() {
        Task {
            await model.connection.connect()
            model.refreshAccess()
            await model.refreshConnection()
        }
    }
}
