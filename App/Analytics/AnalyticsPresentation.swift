import SwiftUI

/// Analytics panels share a quiet edge; chart series and controls carry the color.
private struct AnalyticsPanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.lg)
                    .strokeBorder(Tokens.Surface.border.opacity(contrast == .increased ? 1 : Tokens.Opacity.outline),
                                  lineWidth: Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func analyticsPanel() -> some View { modifier(AnalyticsPanel()) }
}
