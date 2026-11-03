import SwiftUI

/// Shared chrome for the app's sheets and popovers.
struct PopupHeader: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil
    var iconForeground: Color = Tokens.Action.accent
    var iconBackground: Color = Tokens.Surface.muted
    var iconAction: (() -> Void)? = nil
    /// Help and VoiceOver text for the icon button.
    var iconActionLabel = "Choose Icon"

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            if let iconAction {
                Button(action: iconAction) { icon }
                    .buttonStyle(.plain)
                    .focusable()
                    .onKeyPress(keys: [.return, .space]) { _ in
                        iconAction()
                        return .handled
                    }
                    .help(iconActionLabel)
                    .accessibilityLabel(iconActionLabel)
            } else {
                icon.accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title)
                    .font(Tokens.Typography.sectionTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(Tokens.Typography.metadata)
                        .foregroundStyle(Tokens.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding([.horizontal, .top], Tokens.Space.s5)
        .padding(.bottom, Tokens.Space.s4)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(Tokens.Typography.controlSymbol)
            .foregroundStyle(iconForeground)
            .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            .background(iconBackground, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(alignment: .bottomTrailing) {
                if iconAction != nil {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(Tokens.Typography.finePrint)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.primary, Tokens.Surface.primary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
    }
}

struct PopupFooter<Actions: View>: View {
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Tokens.Space.s2) {
                Spacer(minLength: 0)
                actions
            }
            .padding(Tokens.Space.s4)
            .background(Tokens.Surface.muted)
        }
    }
}
