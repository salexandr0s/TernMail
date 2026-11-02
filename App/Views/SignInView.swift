import AppKit
import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                    HStack(alignment: .top, spacing: Tokens.Space.s5) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                            Text(title)
                                .font(.largeTitle.bold())
                                .accessibilityAddTraits(.isHeader)
                            Text(message)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()

                    if model.auth.isConfigured {
                        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                            Button {
                                Task { await model.signIn() }
                            } label: {
                                HStack(spacing: Tokens.Space.s2) {
                                    ZStack {
                                        Image(systemName: "person.crop.circle")
                                            .opacity(model.isSigningIn ? 0 : 1)
                                        if model.isSigningIn {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                    .frame(width: Tokens.Control.icon, height: Tokens.Control.icon)
                                    .accessibilityHidden(true)
                                    Text("Sign In with Google")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Tokens.Space.s1)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(model.isSigningIn)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityLabel(model.isSigningIn ? "Signing in with Google" : "Sign In with Google")
                            .accessibilityIdentifier("sign-in.continue")
                            if model.isSigningIn {
                                Button("Cancel Sign-In") { model.auth.cancelSignIn() }
                                    .buttonStyle(.link)
                                    .keyboardShortcut(.cancelAction)
                            }
                        }
                    } else {
                        TernBadge(text: "Sign-in unavailable", systemImage: "exclamationmark.circle")
                    }

                    if let error = model.signInError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(Tokens.Status.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Tokens.Space.s3)
                            .ternSurface(style: .grouped)
                            .accessibilityIdentifier("sign-in.error")
                    }

                    if case .signInRequired = model.phase {
                        Button("Sign Out…") { model.isConfirmingSignOut = true }
                            .buttonStyle(.link)
                    }
                }
                .padding(Tokens.Space.s8)
                .frame(maxWidth: Tokens.Settings.editorWideWidth)
                .ternSurface(style: .content)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sign-in.content")
                .padding(Tokens.Workspace.pageGutter)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Tokens.Surface.canvas)
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
            return "Sign in to reconnect \(account.email). Your downloaded mail is still here."
        }
        return "Sign in to read and organize your Gmail. Allow Contacts for address suggestions and profile photos."
    }
}
