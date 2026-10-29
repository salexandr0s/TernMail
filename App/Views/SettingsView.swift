import MailStore
import SwiftUI

/// Tern > Settings.
struct SettingsView: View {
    /// Both panes share it, so switching tabs doesn't change the window's width.
    static let width = Tokens.Sheet.smallWidth + Tokens.Space.s16
    static let height = Tokens.Popover.maxListHeight + Tokens.Space.s16

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
        .frame(width: Self.width, height: Self.height)
    }
}

private struct GeneralSettings: View {
    @AppStorage(UndoSendDelay.key) private var undoSendDelay = UndoSendDelay.defaultSeconds
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false

    var body: some View {
        Form {
            Section {
                Picker("Undo send delay", selection: $undoSendDelay) {
                    ForEach(UndoSendDelay.choices, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Label("Sending", systemImage: "paperplane")
            } footer: {
                Text("Tern waits this long before sending, so you can undo.")
            }
            Section {
                Toggle("Use single-key shortcuts", isOn: $usesSingleKeys)
            } header: {
                Label("Keyboard", systemImage: "keyboard")
            } footer: {
                Text("Press E to archive or J and K to move between conversations while you aren't typing. See Help ▸ Keyboard Shortcuts for the full list.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The signed-in accounts, with Add Account, Sign In Again and Sign Out.
private struct AccountsSettings: View {
    @Environment(AppModel.self) private var app
    /// Its own confirmation, since the main window's shows over that window.
    @State private var accountToSignOut: AccountRecord?

    var body: some View {
        Form {
            if let mailbox = app.mailbox, !mailbox.accounts.isEmpty {
                Section {
                    ForEach(mailbox.accounts, id: \.account.id) { owner in
                        row(owner.account)
                    }
                } header: {
                    Label("Google accounts", systemImage: "person.2")
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                        Label("No accounts connected", systemImage: "person.crop.circle.badge.plus")
                            .font(.headline)
                        Text("Add a Google account to read and organize your Gmail.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Tokens.Space.s2)
                }
            }
            Section {
                HStack(spacing: Tokens.Space.s2) {
                    if app.isSigningIn {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Signing in")
                    }
                    Spacer()
                    Button {
                        Task { await app.addAccount() }
                    } label: {
                        Label("Add Account…", systemImage: "plus")
                    }
                    .disabled(app.isSigningIn || !app.auth.isConfigured)
                }
                if let error = app.signInError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !app.auth.isConfigured {
                    Text("Google sign-in isn't available in this version of Tern.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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

    private func row(_ account: AccountRecord) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            TernAvatar(name: account.displayName ?? account.email)
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(account.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? account.email)
                        .font(.headline)
                        .lineLimit(1)
                        .help(account.displayName ?? account.email)
                    if let name = account.displayName, !name.isEmpty {
                        Text(account.email)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(account.email)
                    }
                }
                HStack(spacing: Tokens.Space.s2) {
                    if app.accountsNeedingSignIn.contains(account.id) {
                        Button("Sign In Again") {
                            Task { await app.signInAgain(to: account.id) }
                        }
                        .disabled(app.isSigningIn)
                        .help("Google ended this account's session. Sign in to keep its mail up to date.")
                    }
                    Button("Sign Out…") { accountToSignOut = account }
                        .accessibilityLabel("Sign out of \(account.email)")
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Space.s2)
    }
}
