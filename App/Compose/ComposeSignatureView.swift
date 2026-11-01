import MessageContent
import SwiftUI

/// A saved signature is displayed separately so body edits cannot change it.
struct ComposeSignatureView: View {
    let html: String
    @State private var height = Tokens.Space.s8
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: Tokens.Space.s3)
                    Image(systemName: "signature")
                        .frame(width: Tokens.Control.icon)
                    Text("Signature")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: Tokens.Space.s2)
                    Text("Included")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.vertical, Tokens.Space.s2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide signature preview" : "Show signature preview")
            .accessibilityLabel("Signature")
            .accessibilityValue(isExpanded ? "Expanded, included in message" : "Collapsed, included in message")
            .accessibilityHint("Shows or hides the preview. The signature stays in the message.")
            if isExpanded {
                ScrollView {
                    MessageWebView(html: MessageDocument.render(html: html).html, blocker: nil, height: $height)
                        .frame(height: height)
                }
                .frame(height: min(height, Tokens.Layout.quoteMaxHeight))
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s2)
            }
        }
        .background(Tokens.Surface.muted)
        .overlay(alignment: .top) { Divider() }
        .ternAnimation(value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved signature")
    }
}
