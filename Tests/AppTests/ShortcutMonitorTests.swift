import AppKit
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct ShortcutMonitorTests {
    @Test func registeredCallbackConsumesUndoAndMailActionsWithoutForwardingThem() throws {
        let window = ShortcutTestWindow()
        let view = ShortcutMonitor.MonitorView(frame: .zero)
        window.contentView = view
        defer { view.isEnabled = false; view.commandUndo = nil; window.contentView = nil }
        let commandZ = try event("z", modifiers: .command, window: window)
        #expect(commandZ.window === window)
        var undoCount = 0
        view.commandUndo = { undoCount += 1; return true }
        // These are the same closure and event route AppKit uses, rather than
        // calling the lower-level key parser or the undo callback directly.
        #expect(view.monitoredEventHandler(commandZ) == nil)
        #expect(undoCount == 1)
        #expect(view.monitoredEventHandler(try event("z", modifiers: .command, window: window, isRepeat: true)) == nil)
        #expect(undoCount == 1)

        view.commandUndo = { false }
        #expect(view.monitoredEventHandler(commandZ) === commandZ)
        view.commandUndo = nil
        view.isEnabled = true
        var actions: [SingleKeyShortcuts.Action] = []
        view.perform = { actions.append($0); return true }
        #expect(view.monitoredEventHandler(try event("e", window: window)) == nil)
        #expect(view.monitoredEventHandler(try event("g", window: window)) == nil)
        #expect(view.monitoredEventHandler(try event("i", window: window)) == nil)
        #expect(actions == [.archive, .go(.inbox)])
    }

    @Test func registeredCallbackPreservesTypingWindowAndModifierBoundaries() throws {
        let window = ShortcutTestWindow()
        let otherWindow = ShortcutTestWindow()
        let view = ShortcutMonitor.MonitorView(frame: .zero)
        window.contentView = view
        defer { view.commandUndo = nil; window.contentView = nil }
        var undoCount = 0
        view.commandUndo = { undoCount += 1; return true }
        let commandZ = try event("z", modifiers: .command, window: window)
        window.reportedFirstResponder = NSTextView()
        #expect(view.monitoredEventHandler(commandZ) === commandZ)
        window.reportedFirstResponder = nil
        window.reportsMainWindow = false
        #expect(view.monitoredEventHandler(commandZ) === commandZ)
        window.reportsMainWindow = true
        window.reportsKeyWindow = false
        #expect(view.monitoredEventHandler(commandZ) === commandZ)
        window.reportsKeyWindow = true
        let elsewhere = try event("z", modifiers: .command, window: otherWindow)
        #expect(view.monitoredEventHandler(elsewhere) === elsewhere)
        let redo = try event("z", modifiers: [.command, .shift], window: window)
        #expect(view.monitoredEventHandler(redo) === redo)
        #expect(undoCount == 0)
        #expect(view.monitoredEventHandler(commandZ) == nil)
        #expect(undoCount == 1)
    }

    private func event(_ character: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow,
                       isRepeat: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 1, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: isRepeat, keyCode: 6))
    }
}

/// Never ordered onscreen. Its reported focus state exercises dispatch guards
/// without activating a window or changing the user's keyboard focus.
@MainActor private final class ShortcutTestWindow: NSWindow {
    var reportsKeyWindow = true
    var reportsMainWindow = true
    var reportedFirstResponder: NSResponder?
    override var isKeyWindow: Bool { reportsKeyWindow }
    override var isMainWindow: Bool { reportsMainWindow }
    override var firstResponder: NSResponder? { reportedFirstResponder }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
            styleMask: .borderless, backing: .buffered, defer: false)
    }
}
