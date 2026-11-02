import AppKit
import Testing
@testable import Tern

@Suite @MainActor struct WindowCloseGuardTests {
    @Test func registeredNotificationsSurviveTheForwardedDelegate() throws {
        let window = makeWindow()
        defer { window.close() }
        let proxy = WindowCloseGuard.ForwardingDelegate()
        var recipient: RecordingDelegate? = RecordingDelegate()
        let releasedRecipient = NSHashTable<RecordingDelegate>.weakObjects()
        releasedRecipient.add(recipient)
        proxy.next = recipient
        window.delegate = proxy
        #expect(!proxy.responds(to: #selector(NSWindowDelegate.windowDidMove(_:))))

        // NSWindow registers its delegate for these notifications. Posting
        // through the center exercises that registration, not a direct call.
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(recipient?.notifications == [.didResize, .didResignKey])

        recipient = nil
        #expect(releasedRecipient.allObjects.isEmpty)
        #expect(proxy.next == nil)
        #expect(window.delegate === proxy)
        #expect(!proxy.responds(to: #selector(NSWindowDelegate.windowWillClose(_:))))
        withExtendedLifetime(proxy) {
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            window.close()
        }
    }

    @Test func movingTheGuardRestoresEachWindowsDelegate() throws {
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        let firstRecipient = RecordingDelegate()
        let secondRecipient = RecordingDelegate()
        first.delegate = firstRecipient
        second.delegate = secondRecipient
        let view = WindowCloseGuard.GuardView()
        let firstContent = try #require(first.contentView)
        let secondContent = try #require(second.contentView)

        firstContent.addSubview(view)
        #expect(first.delegate === view.delegate)
        #expect(view.delegate.next === firstRecipient)
        view.removeFromSuperview()
        #expect(first.delegate === firstRecipient)
        #expect(view.delegate.next == nil)

        secondContent.addSubview(view)
        #expect(second.delegate === view.delegate)
        #expect(view.delegate.next === secondRecipient)
        WindowCloseGuard.dismantleNSView(view, coordinator: ())
        WindowCloseGuard.dismantleNSView(view, coordinator: ())
        #expect(second.delegate === secondRecipient)
        #expect(view.delegate.next == nil)
        view.removeFromSuperview()
    }

    @Test func detachingDoesNotOverwriteAReplacementDelegate() throws {
        let window = makeWindow()
        defer { window.close() }
        let original = RecordingDelegate()
        let replacement = RecordingDelegate()
        window.delegate = original
        let view = WindowCloseGuard.GuardView()
        try #require(window.contentView).addSubview(view)
        #expect(window.delegate === view.delegate)

        window.delegate = replacement
        view.removeFromSuperview()
        #expect(window.delegate === replacement)
        #expect(view.delegate.next == nil)
    }

    @Test func closeVetoAndOtherDelegateMethodsKeepTheirBehavior() {
        let window = makeWindow()
        defer { window.close() }
        let recipient = RecordingDelegate()
        let proxy = WindowCloseGuard.ForwardingDelegate()
        proxy.next = recipient
        proxy.shouldClose = { _ in false }
        #expect(!proxy.windowShouldClose(window))
        #expect(recipient.closeRequests == 0)

        proxy.shouldClose = { _ in true }
        recipient.allowsClose = false
        #expect(!proxy.windowShouldClose(window))
        #expect(recipient.closeRequests == 1)
        recipient.allowsClose = true
        #expect(proxy.windowShouldClose(window))
        #expect(recipient.closeRequests == 2)
        let selector = #selector(NSWindowDelegate.windowWillReturnUndoManager(_:))
        #expect(proxy.responds(to: selector))
        #expect(proxy.forwardingTarget(for: selector) as AnyObject? === recipient)
        #expect(!proxy.responds(to: NSSelectorFromString("unimplementedWindowDelegateMethod:")))
        window.delegate = proxy
        withExtendedLifetime(proxy) { window.close() }
        #expect(recipient.notifications.filter { $0 == .willClose }.count == 1)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor private final class RecordingDelegate: NSObject, NSWindowDelegate {
        enum Event: Equatable { case didResize, didResignKey, willClose }
        var notifications: [Event] = []
        var closeRequests = 0
        var allowsClose = true
        let undo = UndoManager()

        func windowDidResize(_ notification: Notification) { notifications.append(.didResize) }
        func windowDidResignKey(_ notification: Notification) { notifications.append(.didResignKey) }
        func windowWillClose(_ notification: Notification) { notifications.append(.willClose) }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            closeRequests += 1
            return allowsClose
        }
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }
    }
}
