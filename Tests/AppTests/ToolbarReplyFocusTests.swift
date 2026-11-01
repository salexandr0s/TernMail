import AppKit
import MailStore
import MessageContent
import Observation
import SwiftUI
import Testing
@testable import Tern

/// Opt in only during an authorized foreground test window. These tests
/// activate synthetic windows and exercise the production native actions.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERN_FOREGROUND_QUOTE_TESTS"] == "1"), .serialized)
@MainActor struct ToolbarReplyFocusTests {
    enum Route: String, CaseIterable, Sendable { case standard, compact, shortcut }

    @Test(arguments: Route.allCases)
    func nativeReplyUsesTheCurrentSceneQuote(route: Route) async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let suite = "ToolbarReplyFocusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mailbox = try await makeMailbox(defaults: defaults)
        do {
            try await exercise(route, mailbox: mailbox)
            await mailbox.stop()
        } catch {
            await mailbox.stop()
            throw error
        }
    }

    private func exercise(_ route: Route, mailbox: MailboxModel) async throws {
        let first = QuoteState(quote: quote("first", text: "First selection"))
        let second = QuoteState(quote: quote("second", text: "Other window selection"))
        let firstHost = makeWindow(mailbox: mailbox, state: first, compact: route == .compact)
        let secondHost = makeWindow(mailbox: mailbox, state: second, compact: route == .compact)
        defer { firstHost.window.close(); secondHost.window.close() }
        try await activate(firstHost)
        try await expectReply(route, in: firstHost, state: first)
        first.quote = quote("first", text: "Changed selection")
        try await settle(firstHost)
        try await expectReply(route, in: firstHost, state: first)
        try await activate(secondHost)
        try await expectReply(route, in: secondHost, state: second)
        first.quote = nil
        try await activate(firstHost)
        try await expectReply(route, in: firstHost, state: first)
        second.quote = nil
        try await activate(secondHost)
        try await expectReply(route, in: secondHost, state: second)
    }

    private func expectReply(_ route: Route, in host: Host, state: QuoteState) async throws {
        try #require(NSApp.isActive && host.window.isKeyWindow && host.window.occlusionState.contains(.visible))
        let expected = state.quote
        let previousCount = state.calls.count
        switch route {
        case .standard:
            let item = try visibleItem("mail.reply", in: host.window)
            let view = try #require(item.view)
            if let button = descendants(view).compactMap({ $0 as? NSButton }).first(where: {
                $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor
                    && ($0.title == "Reply" || $0.accessibilityLabel() == "Reply")
            }) {
                button.performClick(nil)
            } else {
                let buttons = accessibilityButtons(in: view).filter {
                    ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == "Reply" && $0.isAccessibilityEnabled()
                }
                try #require(buttons.count == 1, "The visible Reply item must expose its real native or accessibility button")
                try #require(buttons[0].accessibilityPerformPress())
            }
        case .compact:
            let item = try visibleItem("mail.compactReplies", in: host.window)
            let popup = item.view.flatMap { descendants($0).compactMap { $0 as? NSPopUpButton }.first }
            let menu = try #require((item as? NSMenuToolbarItem)?.menu ?? popup?.menu,
                "The compact Reply control must expose its actual native menu")
            menu.update()
            let index = try #require(menu.items.firstIndex { $0.title == "Reply" && $0.isEnabled && $0.action != nil })
            menu.performActionForItem(at: index)
        case .shortcut:
            let monitor = try #require(descendants(host.root).compactMap { $0 as? ShortcutMonitor.MonitorView }.first)
            try #require(monitor.isEnabled && monitor.window === host.window)
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
                context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
            try #require(monitor.monitoredEventHandler(event) == nil)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while state.calls.count == previousCount, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(state.calls.count == previousCount + 1, "The actual native action must reach the production reply callback exactly once")
        #expect(state.calls.last?.kind == .reply)
        #expect(state.calls.last?.quote == expected, "The callback must use the current scene's selection, including a cleared selection")
    }

    struct Call { let kind: ReplyKind; let quote: SelectedMailQuote? }

    @Observable @MainActor final class QuoteState {
        var quote: SelectedMailQuote?
        @ObservationIgnored var calls: [Call] = []
        init(quote: SelectedMailQuote?) { self.quote = quote }
        func reply(_ kind: ReplyKind, _ quote: SelectedMailQuote?) { calls.append(Call(kind: kind, quote: quote)) }
    }

    private struct Content: View {
        let mailbox: MailboxModel
        let state: QuoteState
        let compact: Bool
        let toolbarID: String

        var body: some View {
            FocusReceiver()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusedSceneValue(\.selectedMailQuote, state.quote)
                .background {
                    MailShortcutContext(isEnabled: true) { action, quote in
                        guard action == .reply else { return false }
                        state.reply(.reply, quote)
                        return true
                    }
                }
                .toolbar(id: toolbarID) { MailToolbar(mailbox: mailbox, reply: state.reply, isCompact: compact) }
        }
    }

    private struct FocusReceiver: NSViewRepresentable {
        func makeNSView(context: Context) -> FocusView { FocusView() }
        func updateNSView(_ view: FocusView, context: Context) {}
    }

    private final class FocusView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct Host { let window: NSWindow; let root: NSView }

    private func makeWindow(mailbox: MailboxModel, state: QuoteState, compact: Bool) -> Host {
        let toolbarID = "ToolbarReplyFocusTests.\(UUID().uuidString)"
        let controller = NSHostingController(rootView: Content(mailbox: mailbox, state: state, compact: compact, toolbarID: toolbarID))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: toolbarID)
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_280, height: 400))
        return Host(window: window, root: controller.view)
    }

    private func activate(_ host: Host) async throws {
        var keyedWhileActive = NSApp.isActive
        host.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(NSApp.isActive && host.window.isKeyWindow && host.window.occlusionState.contains(.visible)),
              ContinuousClock.now < deadline {
            if NSApp.isActive && !keyedWhileActive {
                host.window.makeKeyAndOrderFront(nil)
                keyedWhileActive = true
            }
            try await settle(host)
        }
        if !(NSApp.isActive && host.window.isKeyWindow && host.window.occlusionState.contains(.visible)) {
            print("QUOTE_FOCUS_PREFLIGHT: pid=\(ProcessInfo.processInfo.processIdentifier), active=\(NSApp.isActive), key=\(host.window.isKeyWindow), visible=\(host.window.isVisible), unoccluded=\(host.window.occlusionState.contains(.visible)), occlusion=\(host.window.occlusionState.rawValue), keyedWhileActive=\(keyedWhileActive)")
        }
        try #require(NSApp.isActive && host.window.isKeyWindow && host.window.occlusionState.contains(.visible),
            "The authorized foreground quote test did not acquire a visible key window within eight seconds")
        try await settle(host)
        let receiver = try #require(descendants(host.root).compactMap { $0 as? FocusView }.first)
        try #require(host.window.makeFirstResponder(receiver))
        try await settle(host)
        try #require(NSApp.isActive && host.window.isKeyWindow && host.window.firstResponder === receiver,
            "The isolated quote fixture must own native focus")
    }

    private func settle(_ host: Host) async throws {
        for _ in 0..<4 {
            host.window.layoutIfNeeded()
            host.root.layoutSubtreeIfNeeded()
            host.root.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private func visibleItem(_ id: String, in window: NSWindow) throws -> NSToolbarItem {
        try #require(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == id && $0.isVisible && !$0.isHidden },
            "The expected toolbar item must be visible")
    }

    private func accessibilityButtons(in view: NSView) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: Any, depth: Int) {
            guard depth < 16, seen.insert(ObjectIdentifier(object as AnyObject)).inserted else { return }
            if let node = object as? any NSAccessibilityProtocol {
                if node.accessibilityRole() == .button { result.append(node) }
                for child in node.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
            }
            for child in (object as? NSView)?.subviews ?? [] { visit(child, depth: depth + 1) }
        }
        visit(view, depth: 0)
        for child in NSAccessibility.unignoredChildrenForOnlyChild(from: view) { visit(child, depth: 0) }
        if let node = NSAccessibility.unignoredDescendant(of: view) { visit(node, depth: 0) }
        return result
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func quote(_ owner: String, text: String) -> SelectedMailQuote {
        SelectedMailQuote(accountID: owner, threadID: owner, messageID: owner, text: text)
    }

    private func makeMailbox(defaults: UserDefaults) async throws -> MailboxModel {
        let cache = try MailCache.inMemory()
        let account = AccountRecord(id: "quote-fixture", email: "reader@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now)
        try await cache.write { tx in
            let message = MessageRecord(accountID: account.id, id: "message", threadID: "thread", historyID: 1,
                date: .now, snippet: "", sender: "sender@example.invalid", recipients: account.email,
                cc: nil, subject: "Synthetic reply fixture", sizeEstimate: 1)
            try tx.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox])])
            try tx.rebuildThreads([message.threadID], accountID: account.id)
        }
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory, syncEnabled: false,
            listPreferences: MessageListPreferences(defaults: defaults))
        await mailbox.start()
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !mailbox.isListPresentationReady, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            mailbox.selectedThreadIDs = [ThreadKey(accountID: account.id, threadID: "thread")]
            try #require(mailbox.isListPresentationReady && mailbox.canReply,
                "The synthetic selected conversation must enable Reply")
            return mailbox
        } catch {
            await mailbox.stop()
            throw error
        }
    }
}
