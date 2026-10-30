import SwiftUI

/// Official Sign in with ChatGPT artwork, used only to identify the service.
struct ChatGPTBrand: View {
    enum Ink { case automatic, black, white }

    var size: CGFloat = Tokens.Space.s6
    var ink: Ink = .automatic
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image("ChatGPTLogo")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .environment(\.colorScheme, appearance)
            .accessibilityLabel("ChatGPT")
    }

    private var appearance: ColorScheme {
        switch ink {
        case .automatic: colorScheme
        case .black: .light
        case .white: .dark
        }
    }
}

/// The approved label and monochrome button format, with native keyboard focus.
struct ChatGPTSignInButton: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.s2) {
                ChatGPTBrand(size: Tokens.Space.s4, ink: colorScheme == .dark ? .black : .white)
                    .accessibilityHidden(true)
                Text("Continue with ChatGPT")
                    .font(.body.weight(.medium))
            }
            .frame(minHeight: Tokens.Space.s8)
            .padding(.horizontal, Tokens.Space.s3)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        }
        .buttonStyle(ChatGPTSignInStyle())
        .focused($isFocused)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Tokens.Radius.md + Tokens.Space.s1)
                    .strokeBorder(Color.accentColor, lineWidth: Tokens.Border.focus)
                    .padding(-Tokens.Space.s1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Continue with ChatGPT")
        .accessibilityHint("Opens your browser to sign in to ChatGPT.")
    }
}

private struct ChatGPTSignInStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(colorScheme == .dark ? Color.black : .white)
            .background(colorScheme == .dark ? Color.white : .black,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .strokeBorder(colorScheme == .dark ? Color.black : .white,
                                  lineWidth: configuration.isPressed ? Tokens.Border.focus : 0)
                    .padding(Tokens.Space.s1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.5)
    }
}
