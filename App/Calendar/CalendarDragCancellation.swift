import AppKit
import SwiftUI

/// Escape must reach an active pointer gesture even while another control owns focus.
struct CalendarDragCancellation: NSViewRepresentable {
    var isActive: Bool
    let cancel: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.isActive = isActive
        view.cancel = cancel
        view.updateMonitor()
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var isActive = false
        var cancel: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }
        func updateMonitor() {
            guard isActive, window != nil else { stop(); return }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // AppKit invokes local event monitors synchronously on the main thread.
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.isActive, event.window === self.window, event.keyCode == 53 else { return false }
                    self.cancel?()
                    return true
                }
                return consumed ? nil : event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Scroll the timeline's clip view while a drag is held near a viewport edge.
struct CalendarDragAutoScroll: NSViewRepresentable {
    var direction: CGFloat

    func makeNSView(context: Context) -> ScrollView { ScrollView() }
    func updateNSView(_ view: ScrollView, context: Context) { view.setDirection(direction) }
    static func dismantleNSView(_ view: ScrollView, coordinator: ()) { view.stop() }

    final class ScrollView: NSView {
        private var direction: CGFloat = 0
        private var timer: Timer?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() }
        }
        func setDirection(_ value: CGFloat) {
            direction = value
            guard value != 0 else { stop(); return }
            guard timer == nil else { return }
            let timer = Timer(timeInterval: Tokens.Motion.fast, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scroll() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        func stop() { timer?.invalidate(); timer = nil }
        private func scroll() {
            guard let scrollView = enclosingScrollView, let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            let maximum = max(0, document.bounds.height - clip.bounds.height)
            let dy = direction * Tokens.Space.s4 * (document.isFlipped ? 1 : -1)
            let y = min(maximum, max(0, clip.bounds.origin.y + dy))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}
