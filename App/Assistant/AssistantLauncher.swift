import SwiftUI

/// Place below mailbox notices in their shared bottom-right overlay.
struct AssistantLauncher: View {
    @Bindable var model: AssistantModel
    let onOpenSource: (AssistantSource) -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
                .font(.callout.weight(.medium))
                .padding(.horizontal, Tokens.Space.s3)
                .frame(minHeight: Tokens.Control.avatarLarge)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .background(.regularMaterial, in: Capsule())
        .help("Ask about your mail")
        .accessibilityLabel("Open assistant")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AssistantView(
                model: model,
                onOpenSource: onOpenSource,
                onExpand: { openAssistant(fullScreen: true) },
                onDetach: { openAssistant(fullScreen: false) },
                onClose: { isPresented = false }
            )
            .frame(width: Tokens.Sheet.smallWidth, height: Tokens.Layout.shortcutsHeight)
        }
    }

    private func openAssistant(fullScreen: Bool) {
        isPresented = false
        AssistantWindow.open(using: openWindow, fullScreen: fullScreen)
    }
}
