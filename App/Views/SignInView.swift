import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: Tokens.Space.s4) {
            Image(systemName: "envelope.open")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if model.auth.isConfigured {
                Button {
                    Task { await model.signIn() }
                } label: {
                    Text("Sign In with Google")
                        .padding(.horizontal, Tokens.Space.s2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isSigningIn)
                .keyboardShortcut(.defaultAction)

                if model.isSigningIn {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Signing in")
                }
            }

            if let error = model.signInError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .signInRequired = model.phase {
                Button("Sign Out…") { model.isConfirmingSignOut = true }
                    .buttonStyle(.link)
            }
        }
        .padding(Tokens.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Sign out of Tern?", isPresented: $model.isConfirmingSignOut) {
            Button("Sign Out", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text(model.signOutMessage)
        }
    }

    private var title: String {
        if case .signInRequired = model.phase { return "Sign In Again" }
        return "Welcome to Tern"
    }

    private var message: String {
        guard model.auth.isConfigured else {
            return "This build has no Google OAuth client. Set GOOGLE_CLIENT_ID_PREFIX in Config/Secrets.xcconfig and rebuild."
        }
        if case .signInRequired(let account) = model.phase {
            return "Google ended the session for \(account.email). Your cached mail is still here."
        }
        return "Sign in with your Google account to read and organize your Gmail."
    }
}
