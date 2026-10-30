import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite @MainActor struct SidebarLayoutTests {
    @Test func mailboxExpansionKeepsSidebarViewportAndTopRowInPlace() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !mailbox.hasSyncedOnce, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(mailbox.hasSyncedOnce)
        let suite = "SidebarLayoutTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set("", forKey: SidebarView.expandedKey)
        defer { settings.removePersistentDomain(forName: suite) }

        let controller = NSHostingController(rootView: MainView(mailbox: mailbox).environment(app).defaultAppStorage(settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.toolbar = NSToolbar(identifier: "SidebarLayoutTests")
        window.toolbarStyle = .unified
        window.orderFront(nil)
        defer { window.close() }
        try await settle()
        // AppKit's subview order does not match the split columns' visual order.
        let table = try #require(tables(in: controller.view).min {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        })
        let scroll = try #require(table.enclosingScrollView)
        scrollToTop(scroll)
        try await settle()
        let viewport = scroll.convert(scroll.bounds, to: nil)
        let topRow = table.convert(table.rect(ofRow: 1), to: nil).maxY
        let scrollInsets = scroll.contentInsets
        let clipInsets = scroll.contentView.contentInsets

        // Native selection uses MailboxID tags, even though the binding is optional.
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await settle()
        #expect(mailbox.selectedMailbox == .combined(SystemLabel.starred))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await settle()
        #expect(mailbox.selectedMailbox == .combined(SystemLabel.inbox))
        settings.set(SystemLabel.inbox, forKey: SidebarView.expandedKey)
        try await settle()
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        try await settle()
        #expect(mailbox.selectedMailbox == .account(mailbox.accounts[0].account.id, SystemLabel.inbox))
        settings.set("", forKey: SidebarView.expandedKey)
        try await settle()

        // Alternate populated and empty mailboxes, including the Outbox's own List.
        var expanded = Set<String>()
        for id in [MailboxModel.snoozedID, SystemLabel.spam, SystemLabel.trash,
                   MailboxModel.snoozedID, SystemLabel.trash, MailboxModel.snoozedID,
                   SystemLabel.draft, MailboxModel.outboxID, SystemLabel.inbox,
                   MailboxModel.outboxID, SystemLabel.inbox] {
            mailbox.selectedMailbox = .combined(id)
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            settings.set(expanded.sorted().joined(separator: ","), forKey: SidebarView.expandedKey)
            try await settle()
            #expect(table.window === window)
            #expect(scroll.contentInsets.top == scrollInsets.top)
            #expect(scroll.contentInsets.bottom == scrollInsets.bottom)
            #expect(scroll.contentView.contentInsets.top == clipInsets.top)
            #expect(scroll.contentView.contentInsets.bottom == clipInsets.bottom)
            let current = scroll.convert(scroll.bounds, to: nil)
            #expect(abs(current.minY - viewport.minY) < 1, "Mailbox: \(id)")
            #expect(abs(current.height - viewport.height) < 1, "Mailbox: \(id)")
            // Native selection anchoring may scroll as rows appear; compare at the top.
            scrollToTop(scroll)
            try await settle()
            #expect(abs(table.convert(table.rect(ofRow: 1), to: nil).maxY - topRow) < 1, "Mailbox: \(id)")
        }
        await app.signOut()
    }

    private func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }

    private func scrollToTop(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = -.greatestFiniteMagnitude
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func settle() async throws {
        // Allow SwiftUI updates and the asynchronous mailbox observation to lay out.
        try await Task.sleep(for: .milliseconds(200))
    }
}
