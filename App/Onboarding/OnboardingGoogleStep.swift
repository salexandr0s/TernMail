import MailStore
import SwiftUI

struct OnboardingGoogleStep: View {
    @Environment(AppModel.self) private var app

    private var accounts: [AccountRecord] { app.accountPreferences?.orderedRecords ?? app.mailbox?.accounts.map(\.account) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            if accounts.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                    OnboardingFeature(symbol: "tray.2", title: "Every inbox, together",
                                      detail: "Add your personal and work Google accounts. You can keep adding accounts here.")
                    OnboardingFeature(symbol: "person.crop.circle", title: "Familiar faces in your inbox",
                                      detail: "Allow Contacts in Google to see contact photos and address suggestions.")
                }
                .padding(Tokens.Space.s5)
                .ternSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().padding(.leading, Tokens.Space.s5) }
                        accountRow(account)
                    }
                }
                .ternSurface()
                Label("\(accounts.count) Google \(accounts.count == 1 ? "account added" : "accounts added")",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if app.isSigningIn {
                HStack(spacing: Tokens.Space.s3) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Cancel") { app.auth.cancelSignIn() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Cancel Google sign-in")
                }
                .padding(Tokens.Space.s4)
                .ternSurface()
            } else {
                if accounts.isEmpty {
                    connectButton.buttonStyle(.borderedProminent)
                } else {
                    connectButton.buttonStyle(.bordered)
                }
            }
            if OnboardingPreview.isActive {
                OnboardingNote(text: "This preview uses sample accounts. Google sign-in is disabled.", symbol: "info.circle")
            }
            if !app.auth.isConfigured {
                OnboardingError(message: "Google sign-in isn't available in this version of Tern. Install a version with Google sign-in to continue.")
            }
            if let error = app.signInError { OnboardingError(message: error) }
            OnboardingNote(text: "You sign in directly with Google. Tern stores your connection securely in your Mac's Keychain.")
        }
    }

    private var connectButton: some View {
        Button {
            guard !OnboardingPreview.isActive else { return }
            Task { await app.addAccount() }
        } label: {
            Label(accounts.isEmpty ? "Connect Google account" : "Add another Google account",
                  systemImage: accounts.isEmpty ? "person.crop.circle.badge.plus" : "plus")
                .padding(.horizontal, Tokens.Space.s2)
        }
        .controlSize(.large)
        .disabled(!app.auth.isConfigured || OnboardingPreview.isActive)
        .accessibilityIdentifier("onboarding.connectGoogle")
        .accessibilityHint("Opens Google sign-in in your browser.")
    }

    private func accountRow(_ account: AccountRecord) -> some View {
        let name = account.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let needsSignIn = app.accountsNeedingSignIn.contains(account.id) || {
            if case .signInRequired(let expired) = app.phase { return expired.id == account.id }
            return false
        }()
        return HStack(spacing: Tokens.Space.s3) {
            AddressAvatar(accountID: account.id, address: account.email, name: account.displayName ?? "",
                          size: Tokens.Control.avatarLarge)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(name ?? account.email).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(name ?? account.email)
                if name != nil {
                    Text(account.email).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(account.email)
                }
            }
            Spacer(minLength: Tokens.Space.s2)
            if needsSignIn {
                Button("Reconnect") {
                    guard !OnboardingPreview.isActive else { return }
                    Task {
                        if case .signInRequired = app.phase { await app.signIn() }
                        else { await app.signInAgain(to: account.id) }
                    }
                }
                .disabled(app.isSigningIn || !app.auth.isConfigured || OnboardingPreview.isActive)
                .accessibilityLabel("Reconnect \(account.email)")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Tokens.Status.success)
                    .accessibilityLabel("Connected")
            }
        }
        .padding(Tokens.Space.s4)
    }
}
