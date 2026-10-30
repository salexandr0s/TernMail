import AppKit
import SwiftUI

/// Shortcuts for the window this view is in.
/// Single-key actions require a key window without a sheet or text-input focus,
/// and no ⌘, ⌥ or ⌃ modifier. Optional Command-Z handling uses the same focus
/// boundary and additionally requires the main window.
struct ShortcutMonitor: NSViewRepresentable {
    let isEnabled: Bool
    /// Returns false when the action does nothing, so the key goes on to the
    /// focused view.
    let perform: (SingleKeyShortcuts.Action) -> Bool
    /// An active destination can handle Command-Z before the app's standard
    /// Undo menu. Text editing and other windows retain native undo behavior.
    var commandUndo: (() -> Bool)? = nil

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.perform = perform
        view.commandUndo = commandUndo
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.isEnabled = false
        view.commandUndo = nil
    }

    final class MonitorView: NSView {
        var perform: (SingleKeyShortcuts.Action) -> Bool = { _ in false }
        var commandUndo: (() -> Bool)? {
            didSet { updateMonitor() }
        }
        var isEnabled = false {
            didSet { updateMonitor() }
        }
        private var keys = SingleKeyShortcuts()
        private var monitor: Any?
        /// This exact callback is registered with AppKit. Keeping it separate
        /// also lets tests dispatch synthetic events without posting user input.
        private(set) lazy var monitoredEventHandler: (NSEvent) -> NSEvent? = { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        private func updateMonitor() {
            let isWanted = (isEnabled || commandUndo != nil) && window != nil
            if isWanted, monitor == nil {
                // AppKit calls local monitors on the main thread.
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: monitoredEventHandler)
            } else if !isWanted, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
                keys.reset()
            }
        }

        /// Returns nil for a key it used, so nothing else sees it.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                  !Self.isTyping(in: window)
            else {
                keys.reset()
                return event
            }
            if let commandUndo,
               event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "z" {
                keys.reset()
                guard window.isMainWindow, NSApp.modalWindow == nil else { return event }
                if event.isARepeat { return nil }
                return commandUndo() ? nil : event
            }
            guard isEnabled, SingleKeyShortcuts.accepts(event.modifierFlags), let characters = event.characters else {
                keys.reset()
                return event
            }
            let shift = event.modifierFlags.contains(.shift)
            switch keys.outcome(for: characters, shift: shift, isRepeat: event.isARepeat, at: event.timestamp) {
            case .perform(let action):
                return perform(action) ? nil : event
            case .awaitingDestination, .held:
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
