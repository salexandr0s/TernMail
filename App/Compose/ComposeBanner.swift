import SwiftUI

/// A note across the top of the window.
struct ComposeBanner: View {
    let systemImage: String
    let text: String
    var isError = false
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
            Image(systemName: systemImage)
                .foregroundStyle(isError ? Tokens.Status.error : Tokens.Status.warning)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button("OK", action: dismiss)
            }
        }
        .font(.callout)
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s2)
        .background(Tokens.Surface.muted)
        .accessibilityElement(children: .combine)
    }
}
