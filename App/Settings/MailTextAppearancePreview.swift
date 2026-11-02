import SwiftUI

/// A local sample makes text preferences visible without opening a message.
struct MailTextAppearancePreview: View {
    enum Context { case reading, writing }

    let font: Font
    var context = Context.reading
    var adaptsDarkMode = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text(context == .reading ? "Alex Morgan" : "To: Jordan Lee")
                    .font(.callout.weight(.semibold))
                Text("A plan for next week").font(.headline)
            }
            .padding(Tokens.Space.s4)
            Divider()
            Text("Hi Jordan,\n\nLet’s make time next week to review the first draft and agree on the next steps.\n\nThanks,\nAlex")
                .font(font)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Tokens.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tokens.Surface.primary)
                .environment(\.colorScheme, context == .reading && !adaptsDarkMode ? .light : colorScheme)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(context == .reading ? "Sample message" : "Sample message in the selected writing font")
    }
}
