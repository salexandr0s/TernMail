import AppKit
import Foundation
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct MailSidebarBadgeTests {
    @Test(arguments: [false, true])
    func productionSidebarExposesBadgeValuesThroughNativeAccessibility(severalAccounts: Bool) async throws {
        let cache = try MailCache.inMemory()
        let store = try AccountStore.inMemory()
        let suite = "tern.badges.native." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("", forKey: SidebarExpansion.storageKey)
        defaults.set(false, forKey: "sidebarFavoritesCollapsed")
        let preferences = MessageListPreferences(defaults: defaults)
        preferences.draftsTotal = true
        preferences.spamUnread = true
        let account = AccountRecord(id: "a", email: "a@example.invalid", displayName: "First", grantedScopes: [], addedAt: .now)
        try await store.save(account)
        // Inbox and Drafts exercise the favorite's ignored-child AX container.
        // Spam remains a regular mailbox row, including its combined disclosure.
        let favorites = [SystemLabel.inbox, SystemLabel.draft].enumerated().map {
            MailFavorite(target: .mailbox(labelID: $0.element, scope: .allAccounts), sortOrder: $0.offset)
        }
        try await store.saveMailFavorites(favorites)
        try await cache.write { tx in
            try tx.replaceLabels([
                .init(accountID: "a", id: SystemLabel.inbox, name: "Inbox", isSystem: true,
                    threadsUnread: 2, messagesUnread: 4),
                .init(accountID: "a", id: SystemLabel.draft, name: "Drafts", isSystem: true,
                    threadsTotal: 3, threadsUnread: 1, messagesTotal: 6, messagesUnread: 2),
                .init(accountID: "a", id: SystemLabel.spam, name: "Spam", isSystem: true, messagesUnread: 11),
                .init(accountID: "a", id: "research", name: "Research", isSystem: false, threadsUnread: 3),
                .init(accountID: "a", id: "trips", name: "Research/Trips", isSystem: false, threadsUnread: 1)
            ], accountID: "a")
        }
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: .temporaryDirectory,
            snoozeStore: store, syncEnabled: false, listPreferences: preferences)
        if severalAccounts {
            let second = AccountRecord(id: "b", email: "b@example.invalid", displayName: "Second", grantedScopes: [], addedAt: .now)
            try await store.save(second)
            await mailbox.addAccount(second, gmail: AuditGmail(.second), syncEnabled: false)
        }
        mailbox.selectedMailbox = severalAccounts ? .combined(SystemLabel.sent) : .account("a", SystemLabel.sent)
        await mailbox.start()
        defer { Task { await mailbox.stop() } }
        try await eventually("Synthetic sidebar metadata and favorites") {
            mailbox.labels.count == 5 && mailbox.navigation.favorites == favorites
        }

        let controller = NSHostingController(rootView: SidebarView(mailbox: mailbox)
            .environment(AppModel()).defaultAppStorage(defaults))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 900),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 360, height: 900))
        window.orderBack(nil)
        defer { window.close(); window.contentViewController = nil }

        func expectValue(_ expected: String, label: String) async throws {
            try await eventually("\(label) must expose AX value “\(expected)”", details: {
                let candidates = self.accessibilityElements(in: controller.view).filter { $0.label == label }
                return candidates.isEmpty ? "No matching accessibility element" : candidates.map {
                    "class=\(type(of: $0.object)), label=\($0.label ?? "nil"), spokenValue=\($0.value ?? "nil")"
                }.joined(separator: "; ")
            }) {
                controller.view.layoutSubtreeIfNeeded()
                return self.accessibilityElements(in: controller.view).contains {
                    $0.label == label && ($0.value ?? "") == expected
                }
            }
        }
        let collapsed = severalAccounts ? ", Collapsed" : ""
        try await expectValue("4 unread" + collapsed, label: "Inbox")
        try await expectValue("6 total" + collapsed, label: "Drafts")
        try await expectValue("11 unread" + collapsed, label: "Spam")
        try await expectValue("3 unread, Collapsed", label: "Research")

        preferences.draftsTotal = false
        try await expectValue("2 unread" + collapsed, label: "Drafts")
        preferences.spamUnread = false
        try await expectValue(severalAccounts ? "Collapsed" : "", label: "Spam")

        if severalAccounts {
            defaults.set(SystemLabel.inbox, forKey: SidebarExpansion.storageKey)
            try await expectValue("Expanded", label: "Inbox")
            let accountName = try #require(mailbox.sidebarAccountNames["a"])
            try await expectValue("4 unread", label: "Inbox, " + accountName)
            defaults.set("", forKey: SidebarExpansion.storageKey)
            try await expectValue("4 unread, Collapsed", label: "Inbox")
        }
        await mailbox.stop()
    }

    @Test func accessibleCountsFollowUnreadTotalAndHiddenBadgePreferences() async throws {
        let cache = try MailCache.inMemory()
        let defaults = try #require(UserDefaults(suiteName: "tern.badges.tests." + UUID().uuidString))
        let preferences = MessageListPreferences(defaults: defaults)
        let account = AccountRecord(id: "a", email: "a@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
        try await cache.write { tx in
            try tx.replaceLabels([
                .init(accountID: "a", id: SystemLabel.inbox, name: "Inbox", isSystem: true,
                    threadsUnread: 2, messagesUnread: 4),
                .init(accountID: "a", id: SystemLabel.draft, name: "Drafts", isSystem: true,
                    threadsTotal: 3, threadsUnread: 1, messagesTotal: 6, messagesUnread: 2),
                .init(accountID: "a", id: SystemLabel.spam, name: "Spam", isSystem: true,
                    messagesUnread: 11)
            ], accountID: "a")
        }
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: .temporaryDirectory,
            syncEnabled: false, listPreferences: preferences)
        await mailbox.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while mailbox.labels.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(mailbox.sidebarBadgeDescription(.account("a", SystemLabel.inbox)) == "4 unread")
        preferences.draftsTotal = true
        #expect(mailbox.sidebarBadgeDescription(.combined(SystemLabel.draft)) == "6 total")
        preferences.draftsTotal = false
        #expect(mailbox.sidebarBadgeDescription(.combined(SystemLabel.draft)) == "2 unread")
        preferences.spamUnread = true
        #expect(mailbox.sidebarBadgeDescription(.account("a", SystemLabel.spam)) == "11 unread")
        preferences.spamUnread = false
        #expect(mailbox.sidebarBadgeDescription(.account("a", SystemLabel.spam)).isEmpty)
        #expect(SidebarDisclosureAccessibility.value(badgeDescription: "6 total", isExpanded: false) == "6 total, Collapsed")
        #expect(SidebarDisclosureAccessibility.value(badgeDescription: "", isExpanded: true) == "Expanded")
        await mailbox.stop()
    }
    private func eventually(_ message: String, details: () -> String = { "" },
                            _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(condition(), "\(message). \(details())")
    }

    private func accessibilityElements(in root: NSView) -> [SidebarAXElement] {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ value: Any) -> [SidebarAXElement] {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = SidebarAXElement(object: object)
            let children = element.children
            return [element] + (children + NSAccessibility.unignoredChildren(from: children)).flatMap(visit)
        }
        func nativeDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(nativeDescendants) }
        // Native list cells may sit below an ignored hosting container rather
        // than directly in the hosting view's AX children. Each asserted label
        // and value must still belong to the same actual accessibility element.
        let roots: [Any] = (root.window.map { [$0] } ?? []) + nativeDescendants(root)
        return roots.flatMap(visit)
    }

    @MainActor private struct SidebarAXElement {
        let object: NSObject
        private func property(_ name: String) -> Any? {
            object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
        }
        var children: [Any] {
            property("accessibilityChildren") as? [Any] ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
        }
        var label: String? {
            property("accessibilityLabel") as? String ?? object.accessibilityAttributeValue(.description) as? String
                ?? object.accessibilityAttributeValue(.title) as? String
        }
        var value: String? {
            // SwiftUI's list AccessibilityNode exposes its spoken value through
            // valueDescription on macOS, while native AppKit rows may use value.
            property("accessibilityValue") as? String
                ?? object.accessibilityAttributeValue(.value) as? String
                ?? property("accessibilityValueDescription") as? String
        }
    }
}
