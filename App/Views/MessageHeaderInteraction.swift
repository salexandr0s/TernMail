import AppKit
import SwiftUI

/// The native overlay yields the measured control rectangles to SwiftUI.
/// AppKit supplies click counts using the user's double-click speed.
struct MessageHeaderClickSurface: NSViewRepresentable {
    let messageID: String
    let isExpanded: Bool
    var controlRects: [CGRect] = []
    let onToggle: () -> Void

    func makeNSView(context: Context) -> MessageHeaderClickView {
        let view = MessageHeaderClickView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MessageHeaderClickView, context: Context) {
        if view.messageID != messageID { view.resetClickSequence() }
        view.messageID = messageID
        view.isExpanded = isExpanded
        view.controlRects = controlRects
        view.onToggle = onToggle
        view.setAccessibilityIdentifier("message-header-surface-\(messageID)")
    }
}

final class MessageHeaderClickView: NSView {
    var messageID = ""
    var isExpanded = false
    var controlRects: [CGRect] = []
    var onToggle: () -> Void = {}
    private var beganExpanded = false
    private var mouseDownPoint: NSPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, bounds.contains(local), !controlRects.contains(where: { $0.contains(local) }) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > Tokens.Space.s1 {
            dragged = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragged, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        handleClick(count: event.clickCount)
    }

    func handleClick(count: Int) {
        if count == 1 {
            beganExpanded = isExpanded
            if !beganExpanded { onToggle() }
        } else if count == 2, beganExpanded {
            // A collapsed message already opened on the first click of this sequence.
            onToggle()
        }
    }

    func resetClickSequence() {
        beganExpanded = false
        mouseDownPoint = nil
        dragged = false
    }
}

struct MessageHeaderControlBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func messageHeaderControl() -> some View {
        anchorPreference(key: MessageHeaderControlBounds.self, value: .bounds) { [$0] }
    }
}
