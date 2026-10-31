import AppKit
import Observation
import SwiftUI

/// A standard window: the title bar's green button and View ▸ Enter Full Screen
/// handle full screen, and the toolbar carries the sidebar header's actions.
struct AssistantWindow: View {
    static let sceneID = "assistant"

    @Bindable var model: AssistantModel
    let onOpenSource: (AssistantSource) -> Void
    @State private var window: NSWindow?
    private let presentation = AssistantWindowPresentation.shared

    var body: some View {
        AssistantView(model: model, onOpenSource: onOpenSource, isDetached: true)
            .frame(minWidth: Tokens.Layout.composeMinWidth, minHeight: Tokens.Layout.composeMinHeight)
            .focusedSceneValue(\.assistantModel, model)
            .background {
                AssistantWindowReader { window in
                    self.window = window
                    applyPresentation()
                }
            }
            .onChange(of: presentation.entersFullScreen) { applyPresentation() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard let keyWindow = notification.object as? NSWindow, keyWindow === window else { return }
                applyPresentation()
            }
    }

    /// Opens or brings forward the window. The sidebar's Open Full Screen also
    /// enters full screen; opening never takes the window out of it.
    static func open(using action: OpenWindowAction, fullScreen: Bool) {
        if fullScreen { AssistantWindowPresentation.shared.entersFullScreen = true }
        action(id: sceneID)
    }

    private func applyPresentation() {
        // A new scene must be ordered onscreen before it can enter full screen.
        // The request clears once applied, so reattaching content cannot repeat it.
        guard let window, window.isVisible, presentation.entersFullScreen else { return }
        presentation.entersFullScreen = false
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
}

@MainActor
@Observable
private final class AssistantWindowPresentation {
    static let shared = AssistantWindowPresentation()
    /// Set by Open Full Screen until the window has applied it.
    var entersFullScreen = false
}

/// Capture the hosting window after attachment without searching unrelated windows.
private struct AssistantWindowReader: NSViewRepresentable {
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
