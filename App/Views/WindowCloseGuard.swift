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

    static func dismantleNSView(_ nsView: GuardView, coordinator: ()) {
        nsView.detach()
    }

    final class GuardView: NSView {
        let delegate = ForwardingDelegate()
        private weak var attachedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard attachedWindow !== window else { return }
            detach()
            guard let window else { return }
            attachedWindow = window
            delegate.next = window.delegate
            window.delegate = delegate
        }

        func detach() {
            if let attachedWindow, attachedWindow.delegate === delegate {
                attachedWindow.delegate = delegate.next
            }
            attachedWindow = nil
            delegate.next = nil
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
            // AppKit registers these selectors when the delegate is assigned.
            // Keep that registration unchanged, but retain real implementations
            // for notifications delivered after the weak delegate disappears.
            if let aSelector, Self.notificationSelectors.contains(aSelector) {
                return next?.responds(to: aSelector) == true
            }
            return super.responds(to: aSelector) || next?.responds(to: aSelector) == true
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? { next }

        private static let notificationSelectors: Set<Selector> = [
            #selector(NSWindowDelegate.windowDidResize(_:)),
            #selector(NSWindowDelegate.windowDidExpose(_:)),
            #selector(NSWindowDelegate.windowWillMove(_:)),
            #selector(NSWindowDelegate.windowDidMove(_:)),
            #selector(NSWindowDelegate.windowDidBecomeKey(_:)),
            #selector(NSWindowDelegate.windowDidResignKey(_:)),
            #selector(NSWindowDelegate.windowDidBecomeMain(_:)),
            #selector(NSWindowDelegate.windowDidResignMain(_:)),
            #selector(NSWindowDelegate.windowWillClose(_:)),
            #selector(NSWindowDelegate.windowWillMiniaturize(_:)),
            #selector(NSWindowDelegate.windowDidMiniaturize(_:)),
            #selector(NSWindowDelegate.windowDidDeminiaturize(_:)),
            #selector(NSWindowDelegate.windowDidUpdate(_:)),
            #selector(NSWindowDelegate.windowDidChangeScreen(_:)),
            #selector(NSWindowDelegate.windowDidChangeScreenProfile(_:)),
            #selector(NSWindowDelegate.windowDidChangeBackingProperties(_:)),
            #selector(NSWindowDelegate.windowWillBeginSheet(_:)),
            #selector(NSWindowDelegate.windowDidEndSheet(_:)),
            #selector(NSWindowDelegate.windowWillStartLiveResize(_:)),
            #selector(NSWindowDelegate.windowDidEndLiveResize(_:)),
            #selector(NSWindowDelegate.windowWillEnterFullScreen(_:)),
            #selector(NSWindowDelegate.windowDidEnterFullScreen(_:)),
            #selector(NSWindowDelegate.windowWillExitFullScreen(_:)),
            #selector(NSWindowDelegate.windowDidExitFullScreen(_:)),
            #selector(NSWindowDelegate.windowWillEnterVersionBrowser(_:)),
            #selector(NSWindowDelegate.windowDidEnterVersionBrowser(_:)),
            #selector(NSWindowDelegate.windowWillExitVersionBrowser(_:)),
            #selector(NSWindowDelegate.windowDidExitVersionBrowser(_:)),
            #selector(NSWindowDelegate.windowDidChangeOcclusionState(_:)),
        ]

        func windowDidResize(_ notification: Notification) { next?.windowDidResize?(notification) }
        func windowDidExpose(_ notification: Notification) { next?.windowDidExpose?(notification) }
        func windowWillMove(_ notification: Notification) { next?.windowWillMove?(notification) }
        func windowDidMove(_ notification: Notification) { next?.windowDidMove?(notification) }
        func windowDidBecomeKey(_ notification: Notification) { next?.windowDidBecomeKey?(notification) }
        func windowDidResignKey(_ notification: Notification) { next?.windowDidResignKey?(notification) }
        func windowDidBecomeMain(_ notification: Notification) { next?.windowDidBecomeMain?(notification) }
        func windowDidResignMain(_ notification: Notification) { next?.windowDidResignMain?(notification) }
        func windowWillClose(_ notification: Notification) { next?.windowWillClose?(notification) }
        func windowWillMiniaturize(_ notification: Notification) { next?.windowWillMiniaturize?(notification) }
        func windowDidMiniaturize(_ notification: Notification) { next?.windowDidMiniaturize?(notification) }
        func windowDidDeminiaturize(_ notification: Notification) { next?.windowDidDeminiaturize?(notification) }
        func windowDidUpdate(_ notification: Notification) { next?.windowDidUpdate?(notification) }
        func windowDidChangeScreen(_ notification: Notification) { next?.windowDidChangeScreen?(notification) }
        func windowDidChangeScreenProfile(_ notification: Notification) { next?.windowDidChangeScreenProfile?(notification) }
        func windowDidChangeBackingProperties(_ notification: Notification) { next?.windowDidChangeBackingProperties?(notification) }
        func windowWillBeginSheet(_ notification: Notification) { next?.windowWillBeginSheet?(notification) }
        func windowDidEndSheet(_ notification: Notification) { next?.windowDidEndSheet?(notification) }
        func windowWillStartLiveResize(_ notification: Notification) { next?.windowWillStartLiveResize?(notification) }
        func windowDidEndLiveResize(_ notification: Notification) { next?.windowDidEndLiveResize?(notification) }
        func windowWillEnterFullScreen(_ notification: Notification) { next?.windowWillEnterFullScreen?(notification) }
        func windowDidEnterFullScreen(_ notification: Notification) { next?.windowDidEnterFullScreen?(notification) }
        func windowWillExitFullScreen(_ notification: Notification) { next?.windowWillExitFullScreen?(notification) }
        func windowDidExitFullScreen(_ notification: Notification) { next?.windowDidExitFullScreen?(notification) }
        func windowWillEnterVersionBrowser(_ notification: Notification) { next?.windowWillEnterVersionBrowser?(notification) }
        func windowDidEnterVersionBrowser(_ notification: Notification) { next?.windowDidEnterVersionBrowser?(notification) }
        func windowWillExitVersionBrowser(_ notification: Notification) { next?.windowWillExitVersionBrowser?(notification) }
        func windowDidExitVersionBrowser(_ notification: Notification) { next?.windowDidExitVersionBrowser?(notification) }
        func windowDidChangeOcclusionState(_ notification: Notification) { next?.windowDidChangeOcclusionState?(notification) }
    }
}
