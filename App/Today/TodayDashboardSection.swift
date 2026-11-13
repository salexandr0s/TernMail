import SwiftUI

struct TodaySectionAction {
    let title: String
    var symbol = "plus"
    var isDisabled = false
    var identifier = ""
    let perform: () -> Void
}

struct TodayDashboardSection<Content: View>: View {
    let title: String
    let symbol: String
    let count: Int?
    let countLabel: String?
    /// Names the refresh of content that is already shown. A section with a
    /// label keeps a place for its indicator, so the header never moves.
    let updatingLabel: String?
    let isUpdating: Bool
    let action: TodaySectionAction?
    let content: Content

    init(title: String, symbol: String, count: Int? = nil, countLabel: String? = nil,
         updatingLabel: String? = nil, isUpdating: Bool = false,
         action: TodaySectionAction? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.count = count; self.countLabel = countLabel
        self.updatingLabel = updatingLabel; self.isUpdating = isUpdating
        self.action = action; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title).font(.headline)
                if let count {
                    Text(count.formatted()).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(count) \(countLabel ?? title)")
                        .help("\(count) \(countLabel ?? title)")
                        .ternTransition(.fade)
                }
                if let updatingLabel {
                    // The slot is shorter than the title and the indicator sits over
                    // it, so neither showing nor hiding it changes the header's height.
                    Color.clear.frame(width: Tokens.Space.s4, height: Tokens.Space.s2)
                        .overlay {
                            ProgressView().controlSize(.small).accessibilityLabel(updatingLabel)
                                .ternDelayedLoading(isUpdating)
                        }
                }
                Spacer(minLength: Tokens.Space.s2)
                if let action {
                    Button(action.title, systemImage: action.symbol, action: action.perform)
                        .controlSize(.small).disabled(action.isDisabled)
                        .accessibilityIdentifier(action.identifier)
                }
            }
            .ternAnimation(value: count == nil)
            content
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
        .accessibilityElement(children: .contain)
    }
}
