import SwiftUI

/// A page's identity and context, with room for its primary commands.
struct TernPageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Tokens.Space.s5) {
                heading
                Spacer(minLength: Tokens.Space.s3)
                actions.fixedSize()
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                heading
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
            Text(title)
                .font(Tokens.Workspace.pageTitle)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension TernPageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, actions: { EmptyView() })
    }
}
