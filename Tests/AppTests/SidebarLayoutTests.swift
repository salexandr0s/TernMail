import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite @MainActor struct SidebarLayoutTests {
    @Test func mailboxExpansionKeepsSidebarViewportAndInboxInPlace() async throws {
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
        let inboxRow = try await selectRow(in: table, matching: .combined(SystemLabel.inbox), mailbox: mailbox)
        scrollToTop(scroll)
        try await settle()
        let viewport = scroll.convert(scroll.bounds, to: nil)
        let inboxTop = table.convert(table.rect(ofRow: inboxRow), to: nil).maxY
        let scrollInsets = scroll.contentInsets
        let clipInsets = scroll.contentView.contentInsets

        // Native selection uses MailboxID tags, even though the binding is optional.
        _ = try await selectRow(in: table, matching: .combined(SystemLabel.starred), mailbox: mailbox)
        #expect(mailbox.selectedMailbox == .combined(SystemLabel.starred))
        _ = try await selectRow(in: table, matching: .combined(SystemLabel.inbox), mailbox: mailbox)
        #expect(mailbox.selectedMailbox == .combined(SystemLabel.inbox))
        settings.set(SystemLabel.inbox, forKey: SidebarView.expandedKey)
        try await settle()
        let account = try #require(mailbox.accounts.first?.account)
        _ = try await selectRow(in: table, matching: .account(account.id, SystemLabel.inbox), mailbox: mailbox)
        #expect(mailbox.selectedMailbox == .account(account.id, SystemLabel.inbox))
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
            #expect(abs(table.convert(table.rect(ofRow: inboxRow), to: nil).maxY - inboxTop) < 1, "Mailbox: \(id)")
        }
        await app.signOut()
    }

    private func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }

    private func selectRow(in table: NSTableView, matching mailboxID: MailboxID, mailbox: MailboxModel) async throws -> Int {
        // Probe native selection tags so sections inserted before Mailboxes do
        // not change which rows this test selects. Clearing each selection
        // proves the next native selection updates the optional MailboxID.
        for index in 0..<table.numberOfRows {
            table.deselectAll(nil)
            try await settle()
            try #require(mailbox.selectedMailbox == nil)
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try await settle()
            if mailbox.selectedMailbox == mailboxID { return index }
        }
        throw SidebarSelectionError.mailboxNotFound(mailboxID)
    }

    private enum SidebarSelectionError: Error { case mailboxNotFound(MailboxID) }

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
