import AppKit
import SwiftUI

/// Keeps the keys typed in a compose window while its fields can't take them,
/// then types them into the field that gets the cursor. A new window takes
/// the keyboard before its draft is read, and a message that moves to another
/// account is read-only until its copy opens. Without this, the keys typed
/// meanwhile are lost.
///
/// Shortcuts and Escape are never kept, and neither is a key typed while an
/// editable text field in the window has the cursor.
@MainActor
final class ComposeTypeAhead {
    /// How long the cursor may take to reach the field it was sent to.
    private static let cursorWait: Duration = .milliseconds(500)
    private static let cursorCheck: Duration = .milliseconds(10)
    /// More keys than anyone types ahead. Later ones are not kept.
    private static let capacity = 256
    private static let escapeKeyCode: UInt16 = 53

    private weak var window: NSWindow?
    /// A window starts out unable to take typing.
    private var isHolding = true
    private var held: [NSEvent] = []
    private var monitor: Any?
    /// Waits for the cursor to reach a field before typing the kept keys.
    private var pendingRelease: Task<Void, Never>?
    /// This exact callback is registered with AppKit. Tests call it to type
    /// without posting user input.
    private(set) lazy var monitoredEventHandler: (NSEvent) -> NSEvent? = { [weak self] event in
        // AppKit calls local monitors on the main thread.
        self?.keep(event) == true ? nil : event
    }

    /// The window whose keys to keep. Nil once it closed, which drops them.
    func attach(to window: NSWindow?) {
        self.window = window
        if window == nil { drop() } else { updateMonitor() }
    }

    /// Keeps keys from now on: the fields stopped taking them.
    func hold() {
        pendingRelease?.cancel()
        pendingRelease = nil
        isHolding = true
        updateMonitor()
    }

    /// Types the kept keys into the field that has the cursor and stops
    /// keeping keys. A cursor that was just sent to a field arrives a moment
    /// later, so `waitingForCursor` keeps keys until it does. The keys are
    /// dropped when no field has the cursor.
    func release(waitingForCursor: Bool) {
        guard isHolding, pendingRelease == nil else { return }
        guard waitingForCursor, !hasTextCursor else {
            typeKeys()
            return
        }
        pendingRelease = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.cursorWait)
            while self?.awaitsCursor == true, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.cursorCheck)
                if Task.isCancelled { return }
            }
            self?.pendingRelease = nil
            self?.typeKeys()
        }
    }

    /// Forgets the kept keys and stops keeping keys.
    func drop() {
        pendingRelease?.cancel()
        pendingRelease = nil
        held = []
        isHolding = false
        updateMonitor()
    }

    private var awaitsCursor: Bool { isHolding && window != nil && !hasTextCursor }

    /// An editable text field or text view in the window has the cursor.
    private var hasTextCursor: Bool {
        (window?.firstResponder as? NSText)?.isEditable == true
    }

    private func typeKeys() {
        let keys = held
        drop()
        // Only this window gets the keys, and only while one of its fields
        // has the cursor and no sheet covers it.
        guard let window, window.attachedSheet == nil, hasTextCursor else { return }
        // Each key goes to whichever view has the cursor by then, so a kept
        // Tab moves the keys after it to the next field, as typing would.
        for key in keys { window.sendEvent(key) }
    }

    /// True when the key was kept, so nothing else gets it now.
    private func keep(_ event: NSEvent) -> Bool {
        guard isHolding, let window, event.window === window, window.attachedSheet == nil,
              event.modifierFlags.isDisjoint(with: [.command, .control]), event.keyCode != Self.escapeKeyCode,
              !hasTextCursor, held.count < Self.capacity else { return false }
        held.append(event)
        return true
    }

    private func updateMonitor() {
        let isWanted = isHolding && window != nil
        if isWanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: monitoredEventHandler)
        } else if !isWanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Tells a `ComposeTypeAhead` which window it is in.
struct ComposeTypeAheadAnchor: NSViewRepresentable {
    let typeAhead: ComposeTypeAhead

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.typeAhead = typeAhead
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.typeAhead = typeAhead
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.typeAhead?.attach(to: nil)
    }

    final class AnchorView: NSView {
        var typeAhead: ComposeTypeAhead?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            typeAhead?.attach(to: window)
        }
    }
}
