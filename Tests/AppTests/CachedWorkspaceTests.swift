import AppKit
import Foundation
import MailStore
import SwiftUI
import Testing
@testable import Tern

/// Hosted AppKit inspection needs no system UI-automation permission. The
/// opt-in fixture expires its only account through AppModel's production path.
@Suite(.serialized) @MainActor struct CachedWorkspaceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.arguments.contains("--ui-audit-cached-reauth")))
    func expiredSingleAccountKeepsItsNativeCachedWorkspace() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"),
                     "This test must use isolated synthetic mail.")
        let app = AppModel()
        await app.start()
        do {
            try await inspect(app)
        } catch {
            await stop(app)
            throw error
        }
        await stop(app)
    }

    private func inspect(_ app: AppModel) async throws {
        let mailbox = try #require(app.mailbox)
        let accountID = mailbox.defaultAccount.account.id
        try await eventually("The single synthetic account must reach the production expiry handler") {
            mailbox.hasSyncedOnce && app.accountsNeedingSignIn == [accountID]
                && mailbox.threads.contains { $0.subject == "Field notes" }
        }
        #expect(mailbox.accounts.count == 1)
        #expect(app.mailbox === mailbox)
        #expect(app.phase == .signedIn(mailbox.defaultAccount.account),
                "Expired access must keep the workspace phase and local commands available.")
        let cachedMessage = try await mailbox.cache.read { try $0.message(id: "m1", accountID: accountID) }
        #expect(cachedMessage?.subject == "Field notes")
        app.destination = .mail
        mailbox.selectedMailbox = .account(accountID, SystemLabel.inbox)

        let suite = "tern.tests.cached-workspace.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: MailWindowPreferences.hidesReaderKey)
        defaults.set(false, forKey: "sidebarFavoritesCollapsed")
        defaults.set("", forKey: SidebarExpansion.storageKey)
        defaults.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        let toolbarID = "\(MailWindowPreferences.toolbarID).cached-reauth.\(UUID().uuidString)"
        let controller = NSHostingController(rootView: RootView()
            .environment(app)
            .environment(\.workspaceToolbarID, toolbarID)
            .environment(\.colorScheme, .light)
            .defaultAppStorage(defaults))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 800),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.orderBack(nil)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }

        try await eventually("RootView must expose reconnect, cached Inbox counts, and cached mail together") {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            let elements = self.elements(in: window)
            return elements.contains { $0.id == "account.reconnect" && $0.label?.contains("audit@example.invalid") == true }
                && elements.contains { $0.label?.hasPrefix("Inbox") == true && $0.value == "2 unread" }
                && elements.contains { $0.label?.contains("Field notes") == true || $0.value?.contains("Field notes") == true }
        }
        let tables = descendants(controller.view).compactMap { $0 as? NSTableView }
        #expect(tables.contains { $0.window === window && $0.numberOfRows >= 2 },
                "The cached list must materialize as an attached native table.")

        let thread = try #require(mailbox.threads.first { $0.subject == "Field notes" })
        mailbox.selectedThreadIDs = [thread.key]
        try await eventually("Selecting cached mail must open the native reader while reconnect stays available") {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            let elements = self.elements(in: window)
            return elements.contains { $0.label == "Conversation actions" }
                && elements.contains { $0.id == "account.reconnect" }
        }
        #expect(mailbox.selectedThreadIDs == [thread.key])
        #expect(app.accountsNeedingSignIn == [accountID])
        #expect(app.mailbox === mailbox)

        if let directory = ProcessInfo.processInfo.environment["TERN_CACHED_WORKSPACE_AUDIT_DIR"] {
            try capture(controller.view, directory: directory)
        }
    }

    private func eventually(_ explanation: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(80))
        }
        try #require(condition(), "\(explanation)")
    }

    private func stop(_ app: AppModel) async {
        await app.prepareToQuit()
        await app.mailbox?.stop()
        app.accountPreferences?.stop()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func elements(in window: NSWindow) -> [Element] {
        var seen: Set<ObjectIdentifier> = []
        func visit(_ item: Any) -> [Element] {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = Element(object: object)
            return [element] + (element.children + NSAccessibility.unignoredChildren(from: element.children)).flatMap(visit)
        }
        return ([window] + (window.contentView.map(descendants) ?? [])).flatMap(visit)
    }

    private struct Element {
        let object: NSObject
        private func property(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        var children: [Any] { property("accessibilityChildren") as? [Any] ?? object.accessibilityAttributeValue(.children) as? [Any] ?? [] }
        var id: String? { property("accessibilityIdentifier") as? String ?? object.accessibilityAttributeValue(.identifier) as? String }
        var label: String? { property("accessibilityLabel") as? String ?? object.accessibilityAttributeValue(.description) as? String ?? object.accessibilityAttributeValue(.title) as? String }
        var value: String? { property("accessibilityValue") as? String ?? object.accessibilityAttributeValue(.value) as? String }
    }

    private func capture(_ view: NSView, directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let name = "cached-workspace-after-session-expiry.png"
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        Attachment.record(Array(data), named: name)
    }
}
