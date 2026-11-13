import SwiftUI

/// Presentation motion shared by bars, disclosures and utility panels.
enum TernTransition {
    case disclosure
    case fade
    case panel(edge: Edge)
    /// A notice in the window's corner: it rises a little as it fades in and fades out in place.
    case toast

    var transition: AnyTransition {
        switch self {
        case .disclosure:
            .asymmetric(
                insertion: .opacity.combined(with: .offset(y: -Tokens.Space.s2)),
                removal: .opacity)
        case .fade:
            .opacity
        case .panel(let edge):
            .move(edge: edge).combined(with: .opacity)
        case .toast:
            .asymmetric(
                insertion: .offset(y: Tokens.Space.s2).combined(with: .opacity),
                removal: .opacity)
        }
    }
}

private struct TernPresentationTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let style: TernTransition

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .identity : style.transition)
    }
}

extension View {
    func ternTransition(_ style: TernTransition) -> some View {
        modifier(TernPresentationTransition(style: style))
    }
}
