import AppKit
import SwiftUI

/// Asks `shouldClose` before the close button or File > Close closes the
/// window. Every other delegate call still reaches the delegate SwiftUI installed.
struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: @MainActor (NSWindow) -> Bool

    func makeNSView(context: Context) -> GuardView { GuardView() }

    func updateNSView(_ nsView: GuardView, context: Context) {
        nsView.delegate.shouldClose = shouldClose
    }

    final class GuardView: NSView {
        let delegate = ForwardingDelegate()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== delegate else { return }
            delegate.next = window.delegate
            window.delegate = delegate
        }
    }

    final class ForwardingDelegate: NSObject, NSWindowDelegate {
        weak var next: NSWindowDelegate?
        var shouldClose: @MainActor (NSWindow) -> Bool = { _ in true }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose(sender) else { return false }
            return next?.windowShouldClose?(sender) ?? true
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || next?.responds(to: aSelector) == true
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? { next }
    }
}
