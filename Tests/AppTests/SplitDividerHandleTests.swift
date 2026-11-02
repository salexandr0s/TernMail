import AppKit
import Testing
@testable import Tern

@Suite @MainActor struct SplitDividerHandleTests {
    @Test func dragFromInsidePaneMovesItsDividerAndKeepsNativeConstraints() throws {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        split.isVertical = true
        split.dividerStyle = .thin
        split.arrangesAllSubviews = false
        let panes = (0..<3).map { _ in NSView() }
        panes.forEach(split.addArrangedSubview)
        // Controller-managed split views may also contain decoration views.
        split.addSubview(NSView(), positioned: .below, relativeTo: panes[0])
        let window = NSWindow(contentRect: split.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = split
        defer { window.close() }
        split.adjustSubviews()
        split.setPosition(180, ofDividerAt: 0)
        split.setPosition(480, ofDividerAt: 1)
        let constraints = DividerConstraints()
        split.delegate = constraints

        let container = NSView(frame: panes[1].bounds)
        panes[1].addSubview(container)
        let handle = DividerGrabView(frame: NSRect(x: container.bounds.width - 12, y: 0, width: 12, height: 300))
        container.addSubview(handle)
        let firstDivider = panes[0].frame.maxX
        let secondDivider = panes[1].frame.maxX
        let startX = secondDivider - 6
        handle.mouseEntered(with: try event(.mouseEntered, x: startX, in: window))
        #expect(handle.isHovered)
        handle.mouseDown(with: try event(.leftMouseDown, x: startX, in: window))
        handle.mouseExited(with: try event(.mouseExited, x: startX + 60, in: window))
        #expect(!handle.isHovered && handle.isDragging)
        handle.mouseDragged(with: try event(.leftMouseDragged, x: startX + 60, in: window))
        #expect(abs(panes[1].frame.maxX - (secondDivider + 60)) < 1)
        #expect(panes[0].frame.maxX == firstDivider)
        #expect(split.delegate === constraints)

        handle.mouseDragged(with: try event(.leftMouseDragged, x: 1_200, in: window))
        #expect(panes[1].frame.maxX == 600)
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 0, in: window))
        #expect(panes[1].frame.maxX == 320)
        handle.mouseUp(with: try event(.leftMouseUp, x: 0, in: window))
        #expect(!handle.isDragging && !handle.isHovered)
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 500, in: window))
        #expect(panes[1].frame.maxX == 320)

        handle.mouseDown(with: try event(.leftMouseDown, x: 320, in: window))
        handle.removeFromSuperview()
        #expect(!handle.isDragging && !handle.isHovered)
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 500, in: window))
        #expect(panes[1].frame.maxX == 320)
    }

    @Test func interruptedAssistantDragClearsFeedbackAndIgnoresFurtherDragEvents() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let handle = AssistantSidebarResizeHandle.ResizeView(frame: NSRect(x: 200, y: 0, width: 12, height: 300))
        window.contentView?.addSubview(handle)
        handle.width = 380
        var widths: [CGFloat] = []
        handle.onResize = { widths.append($0) }

        handle.mouseDragged(with: try event(.leftMouseDragged, x: 160, in: window))
        #expect(widths.isEmpty)
        for interruption in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            handle.mouseEntered(with: try event(.mouseEntered, x: 206, in: window))
            handle.mouseDown(with: try event(.leftMouseDown, x: 206, in: window))
            handle.mouseExited(with: try event(.mouseExited, x: 160, in: window))
            #expect(handle.isDragging && !handle.isHovered)
            handle.mouseDragged(with: try event(.leftMouseDragged, x: 160, in: window))
            #expect(widths.last == 426)
            let count = widths.count

            NotificationCenter.default.post(name: interruption,
                object: interruption == NSWindow.didResignKeyNotification ? window : NSApp)
            #expect(!handle.isDragging && !handle.isHovered)
            handle.mouseDragged(with: try event(.leftMouseDragged, x: 100, in: window))
            #expect(widths.count == count)
        }

        handle.mouseDown(with: try event(.leftMouseDown, x: 206, in: window))
        handle.mouseUp(with: try event(.leftMouseUp, x: 160, in: window))
        let count = widths.count
        handle.mouseDragged(with: try event(.leftMouseDragged, x: 100, in: window))
        #expect(widths.count == count)
        #expect(!handle.isDragging && !handle.isHovered)
    }

    @Test func unattachedNativeHandleDoesNotCapturePointerEvents() throws {
        let handle = DividerGrabView(frame: NSRect(x: 0, y: 0, width: 12, height: 300))
        #expect(handle.hitTest(NSPoint(x: 6, y: 100)) == nil)
        handle.updateTrackingAreas()
        #expect(handle.trackingAreas.isEmpty)
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat, in window: NSWindow) throws -> NSEvent {
        if type == .mouseEntered || type == .mouseExited {
            return try #require(NSEvent.enterExitEvent(
                with: type, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
            ))
        }
        return try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
    }
}

@MainActor private final class DividerConstraints: NSObject, NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 1 ? 320 : proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 1 ? 600 : proposedMaximumPosition
    }
}
