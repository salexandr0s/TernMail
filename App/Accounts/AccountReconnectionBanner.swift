import MailStore
import SwiftUI

/// Authentication interrupts synchronization, not access to local mail.
struct AccountReconnectionBanner: View {
    let app: AppModel

    private var accounts: [AccountRecord] {
        app.mailbox?.accounts.map(\.account).filter {
            app.accountsNeedingSignIn.contains($0.id)
        } ?? []
    }

    var body: some View {
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(spacing: Tokens.Space.s3) {
                    Label {
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text(accounts.count == 1
                                ? "Sign in again to sync \(accounts[0].email)."
                                : "Sign in again to sync \(accounts.count) accounts.")
                            Text("Downloaded mail and drafts are still available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Tokens.Status.warning).accessibilityHidden(true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Tokens.Space.s2)
                    if app.isSigningIn {
                        ProgressView().controlSize(.small)
                        Button("Cancel Sign-In") { app.auth.cancelSignIn() }
                    } else if accounts.count == 1, let account = accounts.first {
                        Button("Sign In Again") { reconnect(account) }
                            .accessibilityIdentifier("account.reconnect")
                            .accessibilityLabel("Sign in again to \(account.email)")
                    } else {
                        Menu("Sign In Again") {
                            ForEach(accounts) { account in
                                Button(account.email) { reconnect(account) }
                            }
                        }
                        .accessibilityIdentifier("account.reconnect")
                    }
                }
                if let error = app.signInError { SettingsErrorLabel(error) }
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s3)
            .background(Tokens.Surface.muted)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityIdentifier("account.reauthentication")
        }
    }

    private func reconnect(_ account: AccountRecord) {
        Task { await app.signInAgain(to: account.id) }
    }
}
