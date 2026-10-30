import MessageContent
import SwiftUI

/// A saved signature is displayed separately so body edits cannot change it.
struct ComposeSignatureView: View {
    let html: String
    @State private var height = Tokens.Space.s8

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text("Signature")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                MessageWebView(html: MessageDocument.render(html: html).html, blocker: nil, height: $height)
                    .frame(height: height)
            }
            .frame(height: min(height, Tokens.Layout.quoteMaxHeight))
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Surface.muted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved signature")
    }
}
