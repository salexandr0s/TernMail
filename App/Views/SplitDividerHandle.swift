import AppKit
import SwiftUI

/// A grab gutter beside a pane that leaves its native scrollbar accessible.
struct SplitDividerHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DividerGrabView {
        DividerGrabView()
    }

    func updateNSView(_ view: DividerGrabView, context: Context) {}
}

/// Shared pointer feedback for the native column gutters and assistant divider.
@MainActor
class ResizeHandleView: NSView {
    private var pointerTrackingArea: NSTrackingArea?
    private(set) var isHovered = false { didSet { needsDisplay = true } }
    private(set) var isDragging = false { didSet { needsDisplay = true } }

    var isResizeAvailable: Bool { window != nil && !isHiddenOrHasHiddenAncestor }
    var highlightOriginX: CGFloat { bounds.midX - Tokens.Border.focus / 2 }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isResizeAvailable { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isResizeAvailable else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        pointerTrackingArea = nil
        guard isResizeAvailable else { cancelInteraction(); return }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
        if let window { updateHover(at: window.mouseLocationOutsideOfEventStream) }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = isResizeAvailable }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isResizeAvailable else { return }
        isDragging = true
    }

    override func mouseUp(with event: NSEvent) {
        cancelInteraction()
        updateHover(at: event.locationInWindow)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self)
        cancelInteraction()
        if let newWindow {
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(interactionWasInterrupted),
                    name: name, object: newWindow)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(interactionWasInterrupted),
                name: NSApplication.didResignActiveNotification, object: NSApp)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isResizeAvailable, isHovered || isDragging else { return }
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(isDragging ? Tokens.Opacity.tint : Tokens.Opacity.hover).setFill()
        bounds.fill()
        accent.withAlphaComponent(isDragging ? 1 : Tokens.Opacity.outline).setFill()
        NSRect(x: highlightOriginX, y: bounds.minY, width: Tokens.Border.focus, height: bounds.height).fill()
    }

    func cancelInteraction() {
        isDragging = false
        isHovered = false
    }

    private func updateHover(at point: NSPoint) {
        isHovered = isResizeAvailable && NSApp.isActive && visibleRect.contains(convert(point, from: nil))
    }

    @objc private func interactionWasInterrupted(_ notification: Notification) { cancelInteraction() }
}

final class DividerGrabView: ResizeHandleView {
    private weak var draggedSplitView: NSSplitView?
    private var dividerIndex = 0
    private var initialMouseX: CGFloat = 0
    private var initialPosition: CGFloat = 0

    override var isResizeAvailable: Bool { super.isResizeAvailable && divider != nil }
    override var highlightOriginX: CGFloat { bounds.maxX - Tokens.Border.focus }

    override func mouseDown(with event: NSEvent) {
        guard isResizeAvailable, let divider else { return }
        super.mouseDown(with: event)
        draggedSplitView = divider.split
        dividerIndex = divider.index
        initialMouseX = divider.split.convert(event.locationInWindow, from: nil).x
        initialPosition = divider.pane.frame.maxX
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let splitView = draggedSplitView, splitView.window === window,
              let divider, divider.split === splitView, divider.index == dividerIndex else {
            cancelInteraction()
            return
        }
        let x = splitView.convert(event.locationInWindow, from: nil).x
        let position = initialPosition + x - initialMouseX
        let lower = splitView.minPossiblePositionOfDivider(at: dividerIndex)
        let upper = splitView.maxPossiblePositionOfDivider(at: dividerIndex)
        // setPosition also applies the split view controller's size constraints.
        splitView.setPosition(min(max(position, lower), upper), ofDividerAt: dividerIndex)
    }

    override func cancelInteraction() {
        super.cancelInteraction()
        draggedSplitView = nil
    }

    /// The split's controller and delegate stay in charge of the divider.
    private var divider: EnclosingSplitDivider? { EnclosingSplitDivider(of: self) }
}
