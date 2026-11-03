import CoreGraphics

/// Allocates actual content height after the native toolbar has taken its space.
/// Notices belong to headerHeight; the measured formatting bar is reserved separately.
struct ComposeLayoutBudget: Equatable {
    let header: CGFloat
    let editor: CGFloat
    let supplements: CGFloat

    init(availableHeight: CGFloat, headerHeight: CGFloat, supplementHeight: CGFloat,
         formattingHeight: CGFloat, editorMinimum: CGFloat, dividerHeight: CGFloat) {
        let content = max(0, availableHeight - max(0, formattingHeight) - max(0, dividerHeight))
        let reservedEditor = min(content, max(0, editorMinimum))
        let overflowBudget = max(0, content - reservedEditor)
        let wantedHeader = max(0, headerHeight)
        let wantedSupplements = max(0, supplementHeight)
        // Both overflow routes retain space at short sizes. When either is small,
        // the other can use its unused share before growing the writing viewport.
        let firstHeader = min(wantedHeader, overflowBudget * 0.55)
        let supplements = min(wantedSupplements, overflowBudget - firstHeader)
        let header = min(wantedHeader, overflowBudget - supplements)
        self.header = header
        self.supplements = supplements
        self.editor = max(reservedEditor, content - header - supplements)
    }
}
