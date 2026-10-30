import AppKit
import Observation
import SwiftUI

struct AssistantWindow: View {
    static let sceneID = "assistant"

    @Bindable var model: AssistantModel
    let onOpenSource: (AssistantSource) -> Void
    @State private var window: NSWindow?
    @State private var appliedPresentationID: UUID?
    private let presentation = AssistantWindowPresentation.shared

    var body: some View {
        AssistantView(model: model, onOpenSource: onOpenSource)
            .frame(minWidth: Tokens.Layout.composeMinWidth, minHeight: Tokens.Layout.composeMinHeight)
            .background {
                AssistantWindowReader { window in
                    if self.window !== window { appliedPresentationID = nil }
                    self.window = window
                    applyPresentation()
                }
            }
            .onChange(of: presentation.requestID) { applyPresentation() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard let keyWindow = notification.object as? NSWindow, keyWindow === window else { return }
                applyPresentation()
            }
            .toolbar {
                ToolbarItem {
                    Button("Toggle full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                        guard let window else { return }
                        presentation.request(fullScreen: !window.styleMask.contains(.fullScreen))
                        applyPresentation()
                    }
                    .help("Toggle full screen")
                    .disabled(window == nil)
                }
            }
    }

    static func open(using action: OpenWindowAction, fullScreen: Bool) {
        AssistantWindowPresentation.shared.request(fullScreen: fullScreen)
        action(id: sceneID)
    }

    private func applyPresentation() {
        guard let window else { return }
        // AppKit can ignore toggleFullScreen unless the hosting window opts in.
        window.collectionBehavior.remove([.fullScreenNone, .fullScreenAuxiliary])
        window.collectionBehavior.insert(.fullScreenPrimary)
        // A new scene must be ordered onscreen first. Apply each request once so
        // content reattachment cannot reverse a native fullscreen transition.
        guard window.isVisible, appliedPresentationID != presentation.requestID else { return }
        appliedPresentationID = presentation.requestID
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if presentation.fullScreen != isFullScreen {
            window.toggleFullScreen(nil)
        }
    }
}

@MainActor
@Observable
private final class AssistantWindowPresentation {
    static let shared = AssistantWindowPresentation()
    var requestID = UUID()
    var fullScreen = false

    func request(fullScreen: Bool) {
        self.fullScreen = fullScreen
        requestID = UUID()
    }
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
