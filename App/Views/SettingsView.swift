import MailStore
import SwiftUI

/// Tern > Settings.
struct SettingsView: View {
    /// Both panes share it, so switching tabs doesn't change the window's width.
    static let width: CGFloat = 460

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage(UndoSendDelay.key) private var undoSendDelay = UndoSendDelay.defaultSeconds
    @AppStorage(SingleKeyShortcuts.settingKey) private var usesSingleKeys = false

    var body: some View {
        Form {
            Picker("Undo send delay:", selection: $undoSendDelay) {
                ForEach(UndoSendDelay.choices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .pickerStyle(.menu)
            Text("Tern waits this long before sending, so you can undo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Use single-key shortcuts", isOn: $usesSingleKeys)
                .padding(.top, Tokens.Space.s3)
            Text("Press E to archive, J or K for the next or previous conversation, and more. They work in the main window while you aren't typing. Help ▸ Keyboard Shortcuts lists them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.s6)
        .frame(width: SettingsView.width)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The signed-in accounts, with Add Account, Sign In Again and Sign Out.
private struct AccountsSettings: View {
    private static let height: CGFloat = 300

    @Environment(AppModel.self) private var app
    /// Its own confirmation, since the main window's shows over that window.
    @State private var accountToSignOut: AccountRecord?

    var body: some View {
        Form {
            if let mailbox = app.mailbox {
                Section {
                    ForEach(mailbox.accounts, id: \.account.id) { owner in
                        row(owner.account)
                    }
                } footer: {
                    HStack {
                        Spacer()
                        Button("Add Account…") {
                            Task { await app.addAccount() }
                        }
                        .disabled(app.isSigningIn)
                    }
                }
            } else {
                Text("No accounts. Sign in from the Tern window.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width, height: Self.height)
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
        LabeledContent {
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
        } label: {
            Text(account.email)
                .lineLimit(1)
                .truncationMode(.middle)
            if let name = account.displayName, !name.isEmpty {
                Text(name)
            }
        }
    }
}
