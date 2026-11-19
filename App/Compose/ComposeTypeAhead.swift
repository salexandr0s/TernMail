import AppKit
import SwiftUI

/// Keeps the keys typed in a compose window while its fields can't take them,
/// then types them into the field that gets the cursor. A new window takes
/// the keyboard before its draft is read, and a message that moves to another
/// account is read-only until its copy opens. Without this, the keys typed
/// meanwhile are lost.
///
/// A command that opens a compose window makes the draft first, and the keys
/// typed meanwhile go to the window that was in front. `catchKeys(from:)`
/// keeps those too, and the draft's window takes them when it opens, or once
/// it has the keyboard if it was open already. A mail link or another app
/// can open one while Tern isn't in front, and then `catchKeysInAnyWindow()`
/// keeps the keys typed in any of Tern's windows, except where someone is
/// typing into a field.
///
/// Shortcuts and Escape are never kept, and neither is a key typed while one
/// of the compose window's editable fields has the cursor, unless keys kept
/// earlier haven't reached it yet.
@MainActor
final class ComposeTypeAhead {
    /// How long the cursor may take to reach the field it was sent to.
    private static let cursorWait: Duration = .milliseconds(500)
    private static let cursorCheck: Duration = .milliseconds(10)
    /// How long a command keeps the keys typed in the window it came from.
    /// A draft that takes longer leaves that window its keys again.
    private static let openingWait: Duration = .seconds(2)
    /// How long a window that just opened keeps them, until its own keys come.
    private static let handoverWait: Duration = .seconds(1)
    /// The keys a command kept are dropped when no window took them by then.
    private static let openingLimit: Duration = .seconds(5)
    /// More keys than anyone types ahead. Later ones are not kept.
    private static let capacity = 256
    private static let escapeKeyCode: UInt16 = 53
    /// The keys commands kept, by the draft whose window takes them.
    private static var opening: [String: ComposeTypeAhead] = [:]
    /// Every type-ahead that has kept keys typed in another window.
    private static let keepingOthers = NSHashTable<ComposeTypeAhead>.weakObjects()
    /// Every type-ahead in a compose window. Those windows keep their own keys.
    private static let attached = NSHashTable<ComposeTypeAhead>.weakObjects()

    private weak var window: NSWindow?
    /// The draft the window shows, which a move to another account changes.
    /// A command for it hands its keys over here while the window is open.
    var localDraftID: String?
    /// A window starts out unable to take typing.
    private var isHolding = true
    private var held: [NSEvent] = []
    private var monitor: Any?
    /// Waits for the cursor to reach a field before typing the kept keys.
    private var pendingRelease: Task<Void, Never>?
    /// The window a command came from. Its keys are kept here until
    /// `keptUntil`, or until this window gets keys of its own.
    private weak var keptWindow: NSWindow?
    /// Used in place of `keptWindow` to keep the keys of every window that
    /// `takesKeys(from:)` allows.
    private var keepsAnyWindow = false
    private var keptUntil: ContinuousClock.Instant?
    /// Drops what a command kept when no window takes it.
    private var expiry: Task<Void, Never>?
    /// This exact callback is registered with AppKit. Tests call it to type
    /// without posting user input.
    private(set) lazy var monitoredEventHandler: (NSEvent) -> NSEvent? = { [weak self] event in
        // AppKit calls local monitors on the main thread.
        self?.keep(event) == true ? nil : event
    }

    /// Starts keeping the keys typed in `window`, for a compose window that a
    /// command is about to open. Pass the draft to `wait(for:)` once it
    /// exists, or call `drop()` when there is none.
    static func catchKeys(from window: NSWindow? = NSApp.keyWindow) -> ComposeTypeAhead {
        let typeAhead = ComposeTypeAhead()
        typeAhead.keepKeys(of: .window(window), for: openingWait)
        typeAhead.startOpening()
        return typeAhead
    }

    /// Like `catchKeys(from:)`, for a compose window that opens while Tern
    /// may not be in front, so the keys can reach any of its windows. A
    /// compose window, a sheet or a panel keeps its own keys, and so does a
    /// window where a field has the cursor or an input method is composing.
    static func catchKeysInAnyWindow() -> ComposeTypeAhead {
        let typeAhead = ComposeTypeAhead()
        typeAhead.keepKeys(of: .anyWindow, for: openingWait)
        typeAhead.startOpening()
        return typeAhead
    }

    /// Whether keys typed in `window` are being kept for a compose window
    /// that is opening. Single-key shortcuts leave them alone meanwhile.
    static func keepsKeys(typedIn window: NSWindow) -> Bool {
        keepingOthers.allObjects.contains { $0.keepsKeys(of: window) }
    }

    /// The draft whose window takes the keys kept so far. A window that shows
    /// it already takes them now.
    func wait(for localDraftID: String) {
        guard isHolding, window == nil else { return }
        if let open = Self.attached.allObjects.first(where: { $0.window != nil && $0.localDraftID == localDraftID }) {
            open.take(from: self)
            return
        }
        // A command can run twice for one draft, as on a double click. Both
        // runs' keys go to its window.
        if let earlier = Self.opening[localDraftID], earlier !== self {
            held = Self.merged(earlier.held, held)
            earlier.drop()
        }
        Self.opening[localDraftID] = self
    }

    /// The window whose keys to keep. Nil once it closed, which drops them.
    /// The keys a command kept for `localDraftID` go first.
    func attach(to window: NSWindow?, takingKeysFor localDraftID: String? = nil) {
        self.window = window
        guard window != nil else {
            Self.attached.remove(self)
            drop()
            return
        }
        self.localDraftID = localDraftID
        Self.attached.add(self)
        if let localDraftID, let opening = Self.opening.removeValue(forKey: localDraftID), opening !== self {
            if isHolding {
                held = opening.held + held
                // Keys reach the other windows until this one takes the keyboard.
                if opening.keepsOthers {
                    keepKeys(of: opening.keepsAnyWindow ? .anyWindow : .window(opening.keptWindow),
                             for: Self.handoverWait)
                }
            }
            opening.drop()
        }
        updateMonitor()
    }

    /// Takes the keys `opener` kept for the draft this window shows. The
    /// window is open already and only comes forward, so they wait until it
    /// has the keyboard, and the keys typed in it meanwhile go after them.
    private func take(from opener: ComposeTypeAhead) {
        let typesOnceKey = !isHolding
        held = Self.merged(opener.held, held)
        isHolding = true
        // Keys reach the other windows until this one takes the keyboard.
        if opener.keepsOthers {
            keepKeys(of: opener.keepsAnyWindow ? .anyWindow : .window(opener.keptWindow), for: Self.handoverWait)
        }
        opener.drop()
        updateMonitor()
        // A window that still keeps its own keys types them all when its draft opens.
        if typesOnceKey { releaseOnceKey() }
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

    /// Types the kept keys once the window has the keyboard and one of its
    /// fields has the cursor. After `handoverWait` they go to the field with
    /// the cursor even if the window hasn't come forward.
    private func releaseOnceKey() {
        pendingRelease?.cancel()
        pendingRelease = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.handoverWait)
            while self?.awaitsKeyboard == true, ContinuousClock.now < deadline {
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
        expiry?.cancel()
        expiry = nil
        held = []
        isHolding = false
        keptWindow = nil
        keepsAnyWindow = false
        keptUntil = nil
        Self.opening = Self.opening.filter { $0.value !== self }
        Self.keepingOthers.remove(self)
        updateMonitor()
    }

    private var awaitsCursor: Bool { isHolding && window != nil && !hasTextCursor }

    private var awaitsKeyboard: Bool {
        isHolding && window != nil && !(window?.isKeyWindow == true && hasTextCursor)
    }

    /// An editable text field or text view in the window has the cursor.
    private var hasTextCursor: Bool {
        (window?.firstResponder as? NSText)?.isEditable == true
    }

    /// The windows whose keys are kept for this one until it takes the keyboard.
    private enum Source {
        case window(NSWindow?)
        case anyWindow
    }

    private func keepKeys(of source: Source, for duration: Duration) {
        switch source {
        case .window(let other):
            guard let other else { return }
            keptWindow = other
        case .anyWindow:
            keepsAnyWindow = true
        }
        keptUntil = ContinuousClock.now.advanced(by: duration)
        Self.keepingOthers.add(self)
    }

    /// Watches the keys for a window that is about to open. They are dropped
    /// when no window took them by `openingLimit`.
    private func startOpening() {
        updateMonitor()
        expiry = Task {
            try? await Task.sleep(for: Self.openingLimit)
            if !Task.isCancelled { self.drop() }
        }
    }

    /// Keys typed in other windows are still kept for this one.
    private var keepsOthers: Bool {
        guard isHolding, let keptUntil else { return false }
        return ContinuousClock.now < keptUntil
    }

    private func keepsKeys(of other: NSWindow?) -> Bool {
        guard keepsOthers, let other else { return false }
        return keepsAnyWindow ? Self.takesKeys(from: other) : other === keptWindow
    }

    /// Whether a type-ahead that keeps any window's keys keeps the ones typed
    /// in `other`. A compose window, a sheet or a panel keeps its own, and so
    /// does a window where someone is typing.
    private static func takesKeys(from other: NSWindow) -> Bool {
        !(other is NSPanel) && other.sheetParent == nil && !other.hasTypingFocus
            && !attached.allObjects.contains { $0.window === other }
    }

    private func typeKeys() {
        let keys = held
        drop()
        // Only this window gets the keys, and only while one of its fields
        // has the cursor and no sheet covers it.
        guard let window, window.attachedSheet == nil, hasTextCursor else { return }
        // Each key goes to whichever view has the cursor by then, so a kept
        // Tab moves the keys after it to the next field, as typing would.
        // A key kept from another window is typed as if it came to this one.
        for key in keys {
            if key.window === window {
                window.sendEvent(key)
            } else if let moved = Self.event(key, in: window) {
                window.sendEvent(moved)
            }
        }
    }

    private static func event(_ key: NSEvent, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: key.type, location: .zero, modifierFlags: key.modifierFlags, timestamp: key.timestamp,
                         windowNumber: window.windowNumber, context: nil, characters: key.characters ?? "",
                         charactersIgnoringModifiers: key.charactersIgnoringModifiers ?? "",
                         isARepeat: key.isARepeat, keyCode: key.keyCode)
    }

    /// The keys two type-aheads kept, in the order they were typed.
    private static func merged(_ some: [NSEvent], _ others: [NSEvent]) -> [NSEvent] {
        (some + others).sorted { $0.timestamp < $1.timestamp }
    }

    /// True when the key was kept, so nothing else gets it now.
    private func keep(_ event: NSEvent) -> Bool {
        guard isHolding, event.modifierFlags.isDisjoint(with: [.command, .control]),
              event.keyCode != Self.escapeKeyCode, held.count < Self.capacity else { return false }
        if let window, event.window === window {
            // Keys come to this window now, so the other window's keys are its own again.
            keptUntil = nil
            // The cursor can reach a field just before the kept keys are typed
            // there. A key typed in that moment goes after them.
            guard window.attachedSheet == nil, !hasTextCursor || !held.isEmpty else { return false }
            return append(event)
        }
        return keepsKeys(of: event.window) ? append(event) : false
    }

    private func append(_ event: NSEvent) -> Bool {
        held.append(event)
        return true
    }

    private func updateMonitor() {
        let isWanted = isHolding && (window != nil || keptWindow != nil || keepsAnyWindow)
        if isWanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: monitoredEventHandler)
        } else if !isWanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Tells a `ComposeTypeAhead` which window it is in and which draft the
/// window opened with.
struct ComposeTypeAheadAnchor: NSViewRepresentable {
    let typeAhead: ComposeTypeAhead
    let localDraftID: String?

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.typeAhead = typeAhead
        view.localDraftID = localDraftID
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.typeAhead = typeAhead
        view.localDraftID = localDraftID
        // A move to another account gives the window a copy with an ID of its own.
        typeAhead.localDraftID = localDraftID
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.typeAhead?.attach(to: nil)
    }

    final class AnchorView: NSView {
        var typeAhead: ComposeTypeAhead?
        var localDraftID: String?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            typeAhead?.attach(to: window, takingKeysFor: localDraftID)
        }
    }
}
