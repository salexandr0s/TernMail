import AppKit
import SwiftUI

/// A native view behind the header's content. Each control in front takes its
/// own clicks, and this takes the rest. AppKit supplies click counts using the
/// user's double-click speed.
struct MessageHeaderClickSurface: NSViewRepresentable {
    let messageID: String
    let isExpanded: Bool
    let onToggle: () -> Void

    func makeNSView(context: Context) -> MessageHeaderClickView {
        let view = MessageHeaderClickView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MessageHeaderClickView, context: Context) {
        if view.messageID != messageID {
            view.resetClickSequence()
            view.messageID = messageID
            view.setAccessibilityIdentifier("message-header-surface-\(messageID)")
        }
        view.isExpanded = isExpanded
        view.onToggle = onToggle
    }
}

final class MessageHeaderClickView: NSView {
    var messageID = ""
    var isExpanded = false
    var onToggle: () -> Void = {}
    private var beganExpanded = false
    private var mouseDownPoint: NSPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { false }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

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
