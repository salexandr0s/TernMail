import SwiftUI

/// Draft notices share the header overflow area, so long errors keep a route to recovery.
struct ComposeNotices: View {
    @Bindable var model: ComposeModel
    let availableWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if model.droppedFormatting {
                ComposeBanner(
                    systemImage: "exclamationmark.triangle",
                    text: "Editing this draft removes tables, fonts and other formatting. Only bold, italic, underline, links and lists are kept."
                ) {
                    model.droppedFormatting = false
                }
                .ternTransition(.disclosure)
            }
            if let status = model.status, status.isError {
                ComposeBanner(systemImage: "exclamationmark.circle", text: status.text, isError: true)
                    .ternTransition(.disclosure)
            }
            if let progress = model.progressText {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.vertical, Tokens.Space.s2)
                .background(Tokens.Surface.muted)
                .accessibilityElement(children: .combine)
                .ternTransition(.disclosure)
            } else if availableWidth < Tokens.Compose.labeledToolbarWidth,
                      let status = model.status, !status.isError {
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.Compose.gutter)
                    .padding(.vertical, Tokens.Space.s1_5)
                    .background(Tokens.Surface.muted)
                    .ternTransition(.disclosure)
            }
        }
        .ternAnimation(value: model.droppedFormatting)
        .ternAnimation(value: model.status?.isError == true)
        .ternAnimation(value: model.progressText != nil)
    }
}
