import SwiftUI

/// Outgoing content stays together, separate from files supplied only to the assistant.
struct ComposeIncludedContent<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Included with this message")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Tokens.Compose.gutter)
                .padding(.top, Tokens.Space.s3)
                .padding(.bottom, Tokens.Space.s1)
            content
        }
        .background(Tokens.Surface.muted)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
