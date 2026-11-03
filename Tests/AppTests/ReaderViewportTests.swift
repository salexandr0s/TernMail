import AppKit
import MailStore
import MessageContent
import SwiftUI
import Testing
import WebKit
@testable import Tern

@Suite(.serialized) @MainActor struct ReaderViewportTests {
    @Test(.timeLimit(.minutes(1))) func retainedHiddenReaderDoesNotMarkReadOrReinterpretWhenCalendarContextChanges() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "Hosted reader tests require isolated synthetic accounts")
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox), cache = try #require(app.cache)
        try await waitUntil { mailbox.hasSyncedOnce }
        let calendarStore = try CalendarStore.inMemory()
        app.calendar.store = calendarStore
        let prefix = "reader-lifecycle-\(UUID().uuidString)"
        let first = ThreadKey(accountID: "ui-audit", threadID: prefix + "-first")
        let second = ThreadKey(accountID: "ui-audit", threadID: prefix + "-second")
        try await seed(cache, key: first, count: 1, text: "Planning meeting on November 4, 2030 at 10 am in Room 2.")
        try await seed(cache, key: second, count: 1, text: "A separate synthetic message.")
        let suite = "ReaderViewportTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        settings.set(2.0, forKey: ReadingPreferences.readDelayKey)
        let state = ReaderViewportState(key: first)
        let root = ReaderViewportHarness(state: state, mailbox: mailbox).environment(app).defaultAppStorage(settings)
        let window = try await makeWindow(root)
        defer { window.close(); settings.removePersistentDomain(forName: suite) }
        try await waitUntil { !self.messageViews(in: window.contentView).isEmpty }
        try await waitUntilAsync {
            try await !calendarStore.suggestions(accountID: first.accountID, threadID: first.threadID).isEmpty
        }
        let oldSuggestions = try await calendarStore.suggestions(accountID: first.accountID, threadID: first.threadID)
        let originalView = try #require(messageViews(in: window.contentView).first)
        let oldHours = app.calendar.workingHours
        defer { app.calendar.workingHours = oldHours }
        settings.set(ReadingPreferences.MarkRead.delayed.rawValue, forKey: ReadingPreferences.markReadKey)
        // Advance part of the actual two-second read delay while A remains
        // visible, so switching must cancel an already scheduled timer.
        try #require(window.occlusionState.contains(.visible))
        try await Task.sleep(for: .milliseconds(400))
        state.key = second
        try await waitUntil { self.messageViews(in: window.contentView).count >= 2 }
        app.calendar.workingHours.timeZoneIdentifier = oldHours.timeZoneIdentifier == "UTC" ? "America/New_York" : "UTC"
        // B's real delayed-read timer is the clock and positive control. A's
        // retained view must neither schedule a new timer nor keep its old one.
        try await waitUntilAsync {
            try await cache.read { try $0.currentLabels(threadID: second.threadID, accountID: second.accountID).values.allSatisfy { !$0.contains(SystemLabel.unread) } }
        }
        #expect(try await cache.read { try $0.currentLabels(threadID: first.threadID, accountID: first.accountID).values.allSatisfy { $0.contains(SystemLabel.unread) } })
        let hiddenSuggestions = try await calendarStore.suggestions(accountID: first.accountID, threadID: first.threadID)
        #expect(hiddenSuggestions.map(\.sourceRevision) == oldSuggestions.map(\.sourceRevision))
        #expect(messageViews(in: window.contentView).contains { $0 === originalView })
        #expect(messageViews(in: window.contentView).count <= 3)
        // Returning to A keeps its renderer and allows its calendar context
        // to refresh, proving that the hidden-state assertion had real work.
        state.key = first
        try await waitUntilAsync {
            let updated = try await calendarStore.suggestions(accountID: first.accountID, threadID: first.threadID)
            return updated.map(\.sourceRevision) != oldSuggestions.map(\.sourceRevision)
        }
        #expect(messageViews(in: window.contentView).contains { $0 === originalView })
        window.close()
        await app.signOut()
    }

    @Test(.timeLimit(.minutes(1))) func orderedOutReaderSuspendsReadTimerUntilItsWindowIsVisibleAgain() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox), cache = try #require(app.cache)
        try await waitUntil { mailbox.hasSyncedOnce }
        let prefix = "reader-window-\(UUID().uuidString)"
        let hidden = ThreadKey(accountID: "ui-audit", threadID: prefix + "-hidden")
        let visible = ThreadKey(accountID: "ui-audit", threadID: prefix + "-visible")
        try await seed(cache, key: hidden, count: 1, text: "The hidden reader keeps its unread state.")
        try await seed(cache, key: visible, count: 1, text: "The visible reader supplies the timer control.")
        let suite = "ReaderViewportTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        settings.set(2.0, forKey: ReadingPreferences.readDelayKey)
        let performance = NavigationPerformance.shared
        let bodyGeneration = performance.begin(.reader)
        let headerGeneration = performance.begin(.readerHeader)
        defer {
            performance.cancel(.reader, generation: bodyGeneration)
            performance.cancel(.readerHeader, generation: headerGeneration)
        }
        let hiddenWindow = try await makeWindow(ConversationWindow(link: MailLink(accountID: hidden.accountID, threadID: hidden.threadID))
            .environment(app).defaultAppStorage(settings))
        try await waitUntil { self.messageViews(in: hiddenWindow.contentView).contains { !$0.isLoading && $0.frame.height > 40 } }
        // Opening a standalone conversation cannot claim a main-window
        // selection, including through its otherwise passive native probes.
        #expect(!performance.isReady(.reader, generation: bodyGeneration))
        #expect(!performance.isReady(.readerHeader, generation: headerGeneration))
        #expect(!performance.records.contains { [bodyGeneration, headerGeneration].contains($0.generation) && $0.outcome == .visibleCommit })
        let probes = descendants(in: hiddenWindow.contentView).compactMap { $0 as? VisibleContentProbe.ProbeView }
        try #require(!probes.isEmpty)
        #expect(probes.allSatisfy { !$0.isActive })
        performance.cancel(.reader, generation: bodyGeneration)
        performance.cancel(.readerHeader, generation: headerGeneration)
        settings.set(ReadingPreferences.MarkRead.delayed.rawValue, forKey: ReadingPreferences.markReadKey)
        try #require(hiddenWindow.occlusionState.contains(.visible))
        try await Task.sleep(for: .milliseconds(400))
        hiddenWindow.orderOut(nil)
        // Create the control after hiding A: it cannot occlude A before A's
        // delayed-read timer has had time to start while visible.
        let controlWindow = try await makeWindow(ReaderViewportHarness(state: ReaderViewportState(key: visible), mailbox: mailbox)
            .environment(app).defaultAppStorage(settings))
        defer { hiddenWindow.close(); controlWindow.close(); settings.removePersistentDomain(forName: suite) }
        try await waitUntil { !self.messageViews(in: controlWindow.contentView).isEmpty }
        try await waitUntilAsync {
            try await cache.read { try $0.currentLabels(threadID: visible.threadID, accountID: visible.accountID).values.allSatisfy { !$0.contains(SystemLabel.unread) } }
        }
        #expect(try await cache.read { try $0.currentLabels(threadID: hidden.threadID, accountID: hidden.accountID).values.allSatisfy { $0.contains(SystemLabel.unread) } })
        hiddenWindow.orderFront(nil)
        try await waitUntilAsync {
            try await cache.read { try $0.currentLabels(threadID: hidden.threadID, accountID: hidden.accountID).values.allSatisfy { !$0.contains(SystemLabel.unread) } }
        }
        hiddenWindow.close(); controlWindow.close()
        await app.signOut()
    }

    @Test(.timeLimit(.minutes(1))) func longConversationReusesMeasuredHeightsWhenBodiesReenterTheViewport() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox), cache = try #require(app.cache)
        try await waitUntil { mailbox.hasSyncedOnce }
        let key = ThreadKey(accountID: "ui-audit", threadID: "reader-scroll-\(UUID().uuidString)")
        try await seed(cache, key: key, count: 40, text: String(repeating: "A tall synthetic paragraph for a stable scroll anchor. ", count: 60))
        let suite = "ReaderViewportTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        let window = try await makeWindow(ThreadView(key: key, mailbox: mailbox).environment(app).defaultAppStorage(settings))
        defer { window.close(); settings.removePersistentDomain(forName: suite) }
        try await waitUntil { self.messageViews(in: window.contentView).contains { $0.frame.height > 200 } }
        let scroll = try #require(descendants(in: window.contentView).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.frame.height ?? 0) > $0.frame.height && !self.messageViews(in: $0.documentView).isEmpty
        })
        let initialView = try #require(messageViews(in: window.contentView).first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil { abs(scroll.contentView.bounds.origin.y - 180) < 2 }
        let anchor = scroll.contentView.bounds.origin.y
        let end = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: end))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil { !self.messageViews(in: window.contentView).contains { $0 === initialView } }
        #expect(messageViews(in: window.contentView).count < 8, "Expanded offscreen bodies should remain lightweight")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: anchor))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntilAsync {
            for view in self.messageViews(in: window.contentView) where view !== initialView && view.frame.height > 200 {
                let rectangle = view.convert(view.bounds, to: scroll.contentView)
                guard rectangle.intersects(scroll.contentView.bounds), !view.isLoading else { continue }
                let text = try? await view.evaluateJavaScript("document.body?.innerText", in: nil, contentWorld: .defaultClient) as? String
                if text?.contains("Viewport message 0.") == true { return true }
            }
            return false
        }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(scroll.contentView.bounds.origin.y - anchor) < 2, "Rematerializing a prepared body must not collapse its scroll anchor")
        #expect(messageViews(in: window.contentView).count < 8)
        window.close()
        await app.signOut()
    }

    @Test(.timeLimit(.minutes(1))) func findLoadsOnlyTheUnrealizedMatchingBodyAndRevealsTheNativeSelection() async throws {
        let finder = ReaderFindModel()
        finder.order = (0..<100).map { "message-\($0)" }
        for id in finder.order { finder.setSearchableText(id == "message-90" ? "A unique needle appears here" : "No matching word", for: id) }
        finder.show(); finder.query = "unique needle"; finder.find(forward: true)
        try await waitUntil { finder.requestedMessageID == "message-90" }
        let state = ReaderFindHeight()
        let reader = MessageWebView(html: MessageDocument.render(plainText: "A unique needle appears here").html,
            blocker: await RemoteContentBlocker.ruleList(), height: Binding(get: { state.height }, set: { state.height = $0 }),
            onReadable: { _ in finder.didBecomeReadable("message-90") },
            onCreate: { finder.register($0, for: "message-90") }, onDismantle: { finder.unregister($0) })
        let window = try await makeWindow(reader)
        defer { finder.hide(); window.close() }
        try await waitUntilAsync {
            guard let view = self.messageViews(in: window.contentView).first else { return false }
            return (try? await view.evaluateJavaScript("getSelection()?.toString()", in: nil, contentWorld: .defaultClient) as? String) == "unique needle"
        }
        #expect(!finder.cameUpEmpty)
        #expect(messageViews(in: window.contentView).count == 1)
    }

    @Test func oversizedHiddenSourceLosesItsBytesButKeepsLightweightSessionIdentity() async throws {
        let cache = try MailCache.inMemory()
        let key = ThreadKey(accountID: "account", threadID: "large-source")
        try await seed(cache, key: key, count: 1, text: String(repeating: "x", count: 5 * 1_024 * 1_024))
        var iterator = cache.thread(accountID: key.accountID, threadID: key.threadID).makeAsyncIterator()
        let snapshot = try await iterator.next()
        let detail = try #require(snapshot ?? nil)
        let owner = NSObject(), otherOwner = NSObject()
        let id = ReaderSessionID(key: key, messageID: nil, owner: ObjectIdentifier(owner))
        let otherID = ReaderSessionID(key: key, messageID: nil, owner: ObjectIdentifier(otherOwner))
        let store = ReaderSessionStore(), activeControl = ReaderSessionStore()
        store.setVisible(true, selected: id); store.activate(id); store.record(detail, for: id, selected: id)
        activeControl.setVisible(true, selected: otherID); activeControl.activate(otherID)
        activeControl.record(detail, for: otherID, selected: otherID)
        #expect(store.retainsSource(for: id))
        #expect(activeControl.retainsSource(for: otherID))
        store.setVisible(false, selected: id)
        #expect(!store.retainsSource(for: id))
        #expect(activeControl.retainsSource(for: otherID), "Displayed working content is not evicted by a hidden owner's budget")
        #expect(store.sessions == [id], "Expansion and scroll state keep their existing SwiftUI session identity")
        store.setVisible(true, selected: id)
        #expect(store.retainsSource(for: id))
        // A rapid hide/show may not publish a new detail. Its recorded byte
        // cost must still be enforced the next time it becomes hidden.
        store.setVisible(false, selected: id)
        #expect(!store.retainsSource(for: id))
    }

    private func descendants(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func seed(_ cache: MailCache, key: ThreadKey, count: Int, text: String) async throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try await cache.write { tx in
            for index in 0..<count {
                let id = key.threadID + "-\(index)"
                let record = MessageRecord(accountID: key.accountID, id: id, threadID: key.threadID, historyID: 1,
                    date: date.addingTimeInterval(Double(index)), snippet: "Synthetic reader test", sender: "Synthetic <reader@example.invalid>",
                    recipients: "audit@example.invalid", cc: nil, subject: "Synthetic reader fixture", sizeEstimate: 1_024)
                try tx.upsertMessages([.init(record: record, labelIDs: [SystemLabel.inbox, SystemLabel.unread])])
                try tx.saveBodies([.init(accountID: key.accountID, messageID: id, html: "<p>Viewport message \(index).</p><p>\(text)</p>", plainText: nil, fetchedAt: date)])
                try tx.setBodyEnrichedAt(date, messageID: id, accountID: key.accountID)
            }
            try tx.rebuildThreads([key.threadID], accountID: key.accountID)
        }
    }

    private func makeWindow(_ root: some View) async throws -> NSWindow {
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 760, height: 520))
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        do {
            try await waitUntil {
                NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
            }
        } catch {
            window.close()
            throw error
        }
        #expect(window.contentView?.bounds.size == NSSize(width: 760, height: 520))
        return window
    }
    private func messageViews(in view: NSView?) -> [ContentSizedWebView] {
        guard let view else { return [] }
        return ((view as? ContentSizedWebView).map { [$0] } ?? []) + view.subviews.flatMap { messageViews(in: $0) }
    }
    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        try await waitUntilAsync(sourceLocation: sourceLocation) { condition() }
    }
    private func waitUntilAsync(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try await !condition() {
            try #require(ContinuousClock.now < deadline, "Hosted reader did not reach its expected state", sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor @Observable private final class ReaderViewportState {
    var key: ThreadKey
    init(key: ThreadKey) { self.key = key }
}

private struct ReaderViewportHarness: View {
    let state: ReaderViewportState
    let mailbox: MailboxModel
    var body: some View {
        ReaderSessionContainer(key: state.key, messageID: nil, mailbox: mailbox, isActive: true)
    }
}

@MainActor private final class ReaderFindHeight { var height: CGFloat = 0 }
