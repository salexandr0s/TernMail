import AppKit
import SwiftUI

/// The setup window becomes the mailbox window when onboarding finishes.
/// Attaches only to its hosting window; other scenes keep their own sizing.
struct OnboardingWindowPresentation: NSViewRepresentable {
    let isPresented: Bool
    let reduceMotion: Bool
    let controller: Controller
    var isReady = true

    func makeNSView(context: Context) -> PresentationView { PresentationView() }

    func updateNSView(_ view: PresentationView, context: Context) {
        view.controller = controller
        view.isPresented = isPresented
        view.reduceMotion = reduceMotion
        view.isReady = isReady
        view.updateWindow()
    }

    final class PresentationView: NSView {
        var controller: Controller?
        var isPresented = false
        var reduceMotion = false
        var isReady = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateWindow()
        }

        func updateWindow() {
            guard let window else { return }
            controller?.update(window: window, isPresented: isPresented, reduceMotion: reduceMotion, isReady: isReady)
        }
    }

    /// RootView owns this across changes to its native content hierarchy.
    @MainActor final class Controller {
        private weak var window: NSWindow?
        private var isPresented = false
        private var reduceMotion = false
        private var isReady = false
        private var saved: Configuration?
        private var originalAlpha: CGFloat?
        private var updateTask: Task<Void, Never>?

        func update(window: NSWindow, isPresented: Bool, reduceMotion: Bool, isReady: Bool) {
            if self.window !== window {
                restoreVisibility()
                saved = nil
                self.window = window
            }
            self.isPresented = isPresented
            self.reduceMotion = reduceMotion
            self.isReady = isReady
            // Apply before the first display, while startup chooses the route.
            if !isReady {
                if originalAlpha == nil { originalAlpha = window.alphaValue }
                window.alphaValue = 0
            }
            updateTask?.cancel()
            // Wait until SwiftUI has installed the destination's toolbar.
            updateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.updateWindow()
            }
        }

        private func restoreVisibility() {
            guard let originalAlpha else { return }
            window?.alphaValue = originalAlpha
            self.originalAlpha = nil
        }

        private func updateWindow() {
            guard isReady, let window else { return }
            defer { restoreVisibility() }
            if isPresented {
                guard saved == nil else { return }
                saved = Configuration(window)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.toolbar?.isVisible = false
                let size = NSSize(width: Tokens.Onboarding.width, height: Tokens.Onboarding.height)
                window.setFrame(centeredFrame(contentSize: size, for: window), display: true)
            } else if let saved {
                self.saved = nil
                window.titleVisibility = saved.titleVisibility
                window.titlebarAppearsTransparent = saved.transparentTitlebar
                window.isMovableByWindowBackground = saved.movableBackground
                window.standardWindowButton(.zoomButton)?.isHidden = saved.hiddenZoomButton
                window.toolbar?.isVisible = saved.visibleToolbar
                let size = NSSize(width: max(saved.contentSize.width, Tokens.Layout.windowWidth),
                                  height: max(saved.contentSize.height, Tokens.Layout.windowHeight))
                let frame = centeredFrame(contentSize: size, for: window)
                if reduceMotion {
                    window.setFrame(frame, display: true)
                } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = Tokens.Motion.slow
                        window.animator().setFrame(frame, display: true)
                    }
                }
            }
        }

        private func centeredFrame(contentSize: NSSize, for window: NSWindow) -> NSRect {
            let current = window.frame
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
            if let screen = window.screen?.visibleFrame {
                frame.size.width = min(frame.width, screen.width)
                frame.size.height = min(frame.height, screen.height)
                frame.origin.x = max(screen.minX, min(current.midX - frame.width / 2, screen.maxX - frame.width))
                frame.origin.y = max(screen.minY, min(current.midY - frame.height / 2, screen.maxY - frame.height))
            } else {
                frame.origin = NSPoint(x: current.midX - frame.width / 2, y: current.midY - frame.height / 2)
            }
            return frame
        }

        private struct Configuration {
            let contentSize: NSSize
            let titleVisibility: NSWindow.TitleVisibility
            let transparentTitlebar: Bool
            let movableBackground: Bool
            let hiddenZoomButton: Bool
            let visibleToolbar: Bool

            @MainActor init(_ window: NSWindow) {
                contentSize = window.contentRect(forFrameRect: window.frame).size
                titleVisibility = window.titleVisibility
                transparentTitlebar = window.titlebarAppearsTransparent
                movableBackground = window.isMovableByWindowBackground
                hiddenZoomButton = window.standardWindowButton(.zoomButton)?.isHidden ?? false
                visibleToolbar = window.toolbar?.isVisible ?? true
            }
        }
    }
}
