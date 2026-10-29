import AppKit
import SwiftUI

/// Single-key shortcuts for the window this view is in, the mailbox window.
/// A key counts only while that window is key with no sheet, nothing that
/// takes text has focus, and ⌘, ⌥ and ⌃ aren't held. Compose windows are
/// other windows, so typing there never triggers one.
struct ShortcutMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let perform: (SingleKeyShortcuts.Action) -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.perform = perform
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.isEnabled = false
    }

    final class MonitorView: NSView {
        var perform: (SingleKeyShortcuts.Action) -> Void = { _ in }
        var isEnabled = false {
            didSet { updateMonitor() }
        }
        private var keys = SingleKeyShortcuts()
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        private func updateMonitor() {
            let isWanted = isEnabled && window != nil
            if isWanted, monitor == nil {
                // AppKit calls local monitors on the main thread.
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handle(event) ?? event
                }
            } else if !isWanted, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
                keys.reset()
            }
        }

        /// Returns nil for a key it used, so nothing else sees it.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  SingleKeyShortcuts.accepts(event.modifierFlags), !Self.isTyping(in: window),
                  let characters = event.characters
            else {
                keys.reset()
                return event
            }
            switch keys.outcome(for: characters, shift: event.modifierFlags.contains(.shift), at: event.timestamp) {
            case .perform(let action):
                perform(action)
                return nil
            case .awaitingDestination:
                return nil
            case .ignored:
                return event
            }
        }

        /// A text field or text view has focus, or an input method is composing.
        private static func isTyping(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder else { return false }
            if responder is NSText { return true }
            return (responder as? NSTextInputClient)?.hasMarkedText() ?? false
        }
    }
}
