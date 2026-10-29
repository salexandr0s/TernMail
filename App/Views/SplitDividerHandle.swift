import AppKit
import SwiftUI

/// A grab gutter beside a pane that leaves its native scrollbar accessible.
struct SplitDividerHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DividerGrabView {
        DividerGrabView()
    }

    func updateNSView(_ view: DividerGrabView, context: Context) {}
}

final class DividerGrabView: NSView {
    private weak var draggedSplitView: NSSplitView?
    private var dividerIndex = 0
    private var initialMouseX: CGFloat = 0
    private var initialPosition: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if divider != nil { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard divider != nil else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let (splitView, index) = divider else { return }
        draggedSplitView = splitView
        dividerIndex = index
        initialMouseX = splitView.convert(event.locationInWindow, from: nil).x
        initialPosition = splitView.arrangedSubviews[index].frame.maxX
    }

    override func mouseDragged(with event: NSEvent) {
        guard let splitView = draggedSplitView, splitView.window === window,
              dividerIndex < splitView.arrangedSubviews.count - 1 else { return }
        let x = splitView.convert(event.locationInWindow, from: nil).x
        let position = initialPosition + x - initialMouseX
        let lower = splitView.minPossiblePositionOfDivider(at: dividerIndex)
        let upper = splitView.maxPossiblePositionOfDivider(at: dividerIndex)
        // setPosition also applies the split view controller's size constraints.
        splitView.setPosition(min(max(position, lower), upper), ofDividerAt: dividerIndex)
    }

    override func mouseUp(with event: NSEvent) {
        draggedSplitView = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        draggedSplitView = nil
        window?.invalidateCursorRects(for: self)
    }

    /// SwiftUI may nest split views. Find the divider after this pane using
    /// public view ancestry, leaving its controller and delegate in charge.
    private var divider: (NSSplitView, Int)? {
        var child: NSView = self
        while let parent = child.superview {
            if let splitView = parent as? NSSplitView, splitView.isVertical,
               let index = splitView.arrangedSubviews.firstIndex(where: { $0 === child }),
               index < splitView.arrangedSubviews.count - 1 {
                return (splitView, index)
            }
            child = parent
        }
        return nil
    }
}
