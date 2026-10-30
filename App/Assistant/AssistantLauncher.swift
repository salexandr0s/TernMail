import SwiftUI

/// Opens the assistant beside the reader without changing the window's size.
struct AssistantLauncher: View {
    let isPresented: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Label("Assistant", systemImage: "bubble.left.and.text.bubble.right")
                .font(.callout.weight(.medium))
                .padding(.horizontal, Tokens.Space.s3)
                .frame(minHeight: Tokens.Control.avatarLarge)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .background(.regularMaterial, in: Capsule())
        .help(isPresented ? "Close assistant sidebar" : "Ask about your mail")
        .accessibilityLabel(isPresented ? "Close assistant sidebar" : "Open assistant sidebar")
        .accessibilityValue(isPresented ? "Open" : "Closed")
    }
}
