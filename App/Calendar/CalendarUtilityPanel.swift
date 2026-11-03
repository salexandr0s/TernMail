import SwiftUI

/// One retained subtree for adjacent and compact presentations, including any
/// native field editor and view-owned Tasks or Assistant editing state.
struct CalendarUtilityPanel<Content: View>: View {
    let layout: CalendarUtilityLayout
    let height: CGFloat
    let title: String
    let canClose: Bool
    @FocusState.Binding var backFocused: Bool
    let onBack: () -> Void
    let onResize: (CGFloat) -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.Surface.border)
                .frame(width: layout.isCompact ? 0 : Tokens.Border.hairline)
                .overlay {
                    AssistantSidebarResizeHandle(width: layout.utilityWidth, onResize: onResize)
                        .frame(width: Tokens.Space.s3)
                        .accessibilityElement()
                        .accessibilityLabel("\(title) width")
                        .accessibilityValue("\(Int(layout.utilityWidth)) points")
                        .accessibilityAdjustableAction { direction in
                            onResize(layout.utilityWidth + (direction == .increment ? Tokens.Space.s4 : -Tokens.Space.s4))
                        }
                }
                .opacity(layout.isCompact ? 0 : 1)
                .allowsHitTesting(!layout.isCompact)
                .accessibilityHidden(layout.isCompact)
            VStack(spacing: 0) {
                if layout.isCompact {
                    HStack {
                        Button("Back to Calendar", systemImage: "chevron.left", action: onBack)
                            .buttonStyle(.borderless)
                            .focused($backFocused)
                            .disabled(!canClose)
                            .accessibilityIdentifier("calendar-utility-back")
                        Spacer(minLength: 0)
                    }
                    .padding(Tokens.Space.s3)
                    Divider()
                }
                content
            }
            .frame(width: layout.utilityWidth)
            .background(Tokens.Surface.primary)
        }
        .frame(height: height)
        .offset(x: layout.isCompact ? 0 : layout.calendarWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-utility-panel")
    }
}
