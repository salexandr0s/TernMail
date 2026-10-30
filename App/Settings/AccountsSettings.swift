import MailStore
import SwiftUI

struct AccountsSettings: View {
    @Environment(AppModel.self) private var app
    /// Confirms over Settings rather than the mailbox window.
    @State private var accountToSignOut: AccountRecord?

    var body: some View {
        SettingsPage {
            if let mailbox = app.mailbox, !mailbox.accounts.isEmpty {
                ForEach(mailbox.accounts, id: \.account.id) { owner in
                    VStack(spacing: 0) {
                        row(owner.account)
                        Divider().padding(.horizontal, Tokens.Space.s4)
                        ConnectionsView(account: owner.account, app: app)
                    }
                    .settingsSurface()
                }
            } else {
                HStack(spacing: Tokens.Space.s3) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    SettingsRowLabel("No accounts", detail: "Add a Google account.")
                    Spacer(minLength: 0)
                }
                .padding(Tokens.Space.s3)
                .settingsSurface()
            }
            if let error = app.signInError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(Tokens.Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsSurface()
            }
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
            .padding(.vertical, Tokens.Space.s2)
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
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
    }
}
