import MailStore
import SwiftUI

/// Tern > Settings. Both tabs keep the same window size.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
        .frame(width: Tokens.Layout.settingsWidth, height: Tokens.Layout.settingsHeight)
        .background(Tokens.Surface.canvas)
    }
}

private struct GeneralSettings: View {
    @AppStorage(UndoSendDelay.key) private var undoSendDelay = UndoSendDelay.defaultSeconds
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                SettingsGroup("Sending", systemImage: "paperplane") {
                    HStack(spacing: Tokens.Space.s3) {
                        SettingsRowLabel("Undo Send", detail: "Wait before sending so you can undo.")
                        Spacer(minLength: Tokens.Space.s3)
                        Picker("Undo Send", selection: $undoSendDelay) {
                            ForEach(UndoSendDelay.choices, id: \.self) { seconds in
                                Text("\(seconds) seconds").tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Undo Send delay")
                    }
                    .padding(Tokens.Space.s3)
                }

                SettingsGroup("Keyboard", systemImage: "keyboard") {
                    HStack(spacing: Tokens.Space.s3) {
                        SettingsRowLabel("Single-key shortcuts", detail: "Use letter keys when you aren't typing.")
                        Spacer(minLength: Tokens.Space.s3)
                        Toggle("Single-key shortcuts", isOn: $usesSingleKeys)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .fixedSize()
                            .accessibilityLabel("Single-key shortcuts")
                            .accessibilityHint("Use letter keys when you aren't typing.")
                    }
                    .padding(Tokens.Space.s3)

                    Divider()
                        .padding(.horizontal, Tokens.Space.s3)

                    HStack {
                        Button("View Shortcuts…") {
                            openWindow(id: KeyboardShortcutsView.sceneID)
                        }
                        .buttonStyle(.link)
                        .accessibilityHint("Opens Keyboard Shortcuts")
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Tokens.Space.s3)
                    .padding(.vertical, Tokens.Space.s2)
                }
            }
            .padding(Tokens.Space.s4)
        }
    }
}

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var app
    /// Confirms over Settings rather than the mailbox window.
    @State private var accountToSignOut: AccountRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                if let mailbox = app.mailbox, !mailbox.accounts.isEmpty {
                    SettingsGroup("Google accounts", systemImage: "person.2") {
                        ForEach(mailbox.accounts, id: \.account.id) { owner in
                            if owner.account.id != mailbox.accounts.first?.account.id {
                                Divider()
                                    .padding(.leading, Tokens.Control.avatar + Tokens.Space.s3 * 2)
                                    .padding(.trailing, Tokens.Space.s3)
                            }
                            row(owner.account)
                        }
                    }
                } else {
                    HStack(spacing: Tokens.Space.s3) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        SettingsRowLabel("No accounts", detail: "Add a Google account.")
                        Spacer(minLength: 0)
                    }
                    .padding(Tokens.Space.s3)
                    .ternSurface()
                }
                if let error = app.signInError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(Tokens.Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .ternSurface()
                }
            }
            .padding(Tokens.Space.s4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            accountFooter
        }
        .confirmationDialog(
            "Sign out of \(accountToSignOut?.email ?? "this account")?",
            isPresented: Binding(get: { accountToSignOut != nil }, set: { if !$0 { accountToSignOut = nil } }),
            presenting: accountToSignOut
        ) { account in
            Button("Sign Out", role: .destructive) {
                Task { await app.signOut(of: account.id) }
            }
        } message: { account in
            Text(app.signOutMessage(for: account))
        }
    }

    private var accountFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Tokens.Space.s3) {
                if app.isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Signing in…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !app.auth.isConfigured {
                    Text("Google sign-in is unavailable in this version.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await app.addAccount() }
                } label: {
                    Label("Add Account…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.isSigningIn || !app.auth.isConfigured)
                .fixedSize()
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s3)
        }
        .background(Tokens.Surface.muted)
    }

    private func row(_ account: AccountRecord) -> some View {
        let needsSignIn = app.accountsNeedingSignIn.contains(account.id)
        let name = account.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: Tokens.Space.s3) {
            TernAvatar(name: name ?? account.email)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(name ?? account.email)
                    .font(.body.weight(.semibold))
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
                if needsSignIn {
                    Label("Sign-in required", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: Tokens.Space.s1) {
                if needsSignIn {
                    Button("Sign In Again") {
                        Task { await app.signInAgain(to: account.id) }
                    }
                    .disabled(app.isSigningIn || !app.auth.isConfigured)
                    .help("Sign in again to sync mail.")
                    .accessibilityLabel("Sign in again to \(account.email)")
                }
                Button("Sign Out…") { accountToSignOut = account }
                    .accessibilityLabel("Sign out of \(account.email)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(Tokens.Space.s3)
    }
}

private struct SettingsGroup<Content: View>: View {
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
            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ternSurface()
        }
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(title)
                .font(.body.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
