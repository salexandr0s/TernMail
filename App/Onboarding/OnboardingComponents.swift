import SwiftUI

/// Ordinary previews never open a provider sign-in or write credentials.
enum OnboardingPreview {
    static var isActive: Bool {
        AssistantRuntimeEnvironment.isTestHost || ProcessInfo.processInfo.arguments.contains("--ui-audit")
    }

    static var allowsChatGPTSignIn: Bool {
        !isActive || (!AssistantRuntimeEnvironment.isTestHost
            && ProcessInfo.processInfo.arguments.contains("--ui-audit-live-chatgpt"))
    }
}

extension Tokens {
    enum Onboarding {
        static let width: CGFloat = 1000
        static let height: CGFloat = 600
        static let sidebarWidth: CGFloat = 224
        static let contentWidth: CGFloat = 560
        static let compactWidth: CGFloat = 860
        static let heroIcon = Space.s16 + Space.s8
    }
}

struct OnboardingFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: Tokens.Space.s10, height: Tokens.Space.s10)
                .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingNote: View {
    let text: String
    var symbol = "lock"

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OnboardingError: View {
    let message: String

    var body: some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(Tokens.Status.error)
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
        .accessibilityElement(children: .combine)
    }
}
