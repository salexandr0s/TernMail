import SwiftUI

/// The editor keeps its own native scroll view. Only the two supporting regions scroll here.
/// Measuring SwiftUI content preserves RecipientField's separate-copy measurement contract.
struct ComposeVerticalLayout<Header: View, Formatting: View, Editor: View, Supplements: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var formatting: Formatting
    @ViewBuilder var editor: Editor
    @ViewBuilder var supplements: Supplements
    @State private var headerHeight: CGFloat = 0
    @State private var formattingHeight: CGFloat = 0
    @State private var supplementHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let budget = ComposeLayoutBudget(availableHeight: geometry.size.height,
                headerHeight: headerHeight, supplementHeight: supplementHeight,
                formattingHeight: formattingHeight, editorMinimum: Tokens.Layout.editorMinHeight,
                dividerHeight: Tokens.Border.hairline)
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    header
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
                .frame(height: budget.header)
                .accessibilityIdentifier("compose-header-viewport")
                Divider().frame(height: Tokens.Border.hairline)
                VStack(spacing: 0) { formatting }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formattingHeight = $0 }
                editor
                    .frame(height: budget.editor)
                    .accessibilityIdentifier("compose-editor-viewport")
                ScrollView(.vertical) {
                    supplements
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { supplementHeight = $0 }
                }
                .frame(height: budget.supplements)
                .accessibilityIdentifier("compose-supplements-viewport")
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
    }
}
