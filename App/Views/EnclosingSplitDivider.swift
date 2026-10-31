import AppKit

/// The native divider after the column that holds a view, found through public
/// view ancestry. SwiftUI may nest split views, so the nearest vertical split
/// with a divider after that column wins.
struct EnclosingSplitDivider {
    let split: NSSplitView
    let pane: NSView
    let index: Int

    @MainActor init?(of view: NSView) {
        var child = view
        while let parent = child.superview {
            if let split = parent as? NSSplitView, split.isVertical,
               let index = split.arrangedSubviews.firstIndex(where: { $0 === child }),
               index < split.arrangedSubviews.count - 1 {
                self.split = split
                pane = child
                self.index = index
                return
            }
            child = parent
        }
        return nil
    }
}
