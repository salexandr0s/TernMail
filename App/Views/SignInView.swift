import AppKit
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: Tokens.Space.s6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: Tokens.Space.s16 + Tokens.Space.s8, height: Tokens.Space.s16 + Tokens.Space.s8)
                .accessibilityHidden(true)

            VStack(spacing: Tokens.Space.s3) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: Tokens.Sheet.smallWidth)

            if model.auth.isConfigured {
                Button {
                    Task { await model.signIn() }
                } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        ZStack {
                            Image(systemName: "person.crop.circle")
                                .opacity(model.isSigningIn ? 0 : 1)
                            if model.isSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .frame(width: Tokens.Control.icon, height: Tokens.Control.icon)
                        .accessibilityHidden(true)
                        Text("Sign In with Google")
                    }
                    .padding(.horizontal, Tokens.Space.s3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isSigningIn)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(model.isSigningIn ? "Signing in with Google" : "Sign In with Google")
            } else {
                TernBadge(text: "Sign-in unavailable", systemImage: "exclamationmark.circle")
            }

            if let error = model.signInError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(Tokens.Space.s3)
                    .frame(maxWidth: Tokens.Sheet.smallWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .ternSurface()
            }

            if case .signInRequired = model.phase {
                Button("Sign Out…") { model.isConfirmingSignOut = true }
                    .buttonStyle(.link)
            }
        }
        .padding(Tokens.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Surface.muted)
        .ternAnimation(value: model.isSigningIn)
        .ternAnimation(value: model.signInError)
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
            return "Google sign-in isn't available in this version of Tern."
        }
        if case .signInRequired(let account) = model.phase {
            return "Google ended the session for \(account.email). Your cached mail is still here."
        }
        return "Sign in with your Google account to read and organize your Gmail."
    }
}
