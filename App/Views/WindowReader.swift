import AppKit
import SwiftUI

/// Captures the hosting window after attachment without searching unrelated windows.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class WindowObserverView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            Task { @MainActor [weak self, weak window] in
                guard let window else { return }
                self?.onWindow?(window)
            }
        }
    }
}
