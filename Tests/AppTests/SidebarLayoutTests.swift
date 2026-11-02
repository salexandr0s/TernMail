import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct SidebarLayoutTests {
    @Test func calendarToolbarClearsSidebar() async throws {
        let app = AppModel()
        await app.start()
        // This Calendar uses only synthetic data. Start before seeding so the
        // workspace's startup cannot replace its store or reconcile it against Mail accounts.
        app.calendar.app = nil
        await app.calendar.start()
        await app.calendar.seedCalendarAudit()
        let initiallyWritable = app.calendar.calendars.contains { $0.canWrite }
        try #require(initiallyWritable, "The fixture must allow event creation")
        let mailbox = try #require(app.mailbox)
        let suite = "CalendarToolbarBoundary.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox).environment(app)
            .environment(\.workspaceToolbarID, workspaceToolbarIdentifier()).defaultAppStorage(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.orderBack(nil)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }
        app.destination = .calendar

        func calendarSplit() throws -> NSSplitView {
            let splits = descendants(in: controller.view).compactMap { $0 as? NSSplitView }.filter { split in
                split.isVertical && !descendants(in: split).contains { $0 is MailColumnProbe.ProbeView }
            }
            try #require(splits.count == 1)
            return try #require(splits.first)
        }

        func expectBoundary() async throws {
            try await settle()
            let split = try calendarSplit()
            let railWidth = expectedRailWidth(in: window)
            try expectDestinationControl(in: window)
            try expectCalendarPageControls(in: window)
            if window.frame.width - railWidth < Tokens.Calendar.compactWidth {
                #expect(split.arrangedSubviews.count == 1)
                let content = try #require(split.arrangedSubviews.last)
                #expect(abs(content.convert(content.bounds, to: nil).minX - railWidth) <= 1)
            } else {
                try #require(split.arrangedSubviews.count == 2)
                let sidebar = try #require(split.arrangedSubviews.first)
                let frame = sidebar.convert(sidebar.bounds, to: nil)
                for identifier in leadingToolbarIdentifiers(in: window, section: .calendar) {
                    let item = try #require(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == identifier })
                    let view = try #require(item.view)
                    #expect(view.convert(view.bounds, to: nil).minX >= frame.maxX - 1,
                        "\(identifier) must remain outside Calendar's sidebar")
                }
                #expect(abs(frame.maxY - (window.contentLayoutRect.maxY - Tokens.Border.hairline)) <= 1,
                    "Calendar's sidebar must start below the toolbar without an extra gap: \(frame)")
            }
        }

        for width in [1_280, 1_079, 1_080, 1_081, 960, 720, 1_280] {
            window.setContentSize(NSSize(width: width, height: 760))
            try await expectBoundary()
        }
        let split = try calendarSplit()
        let sidebar = try #require(split.arrangedSubviews.first)
        for width in [Tokens.Layout.sidebarMaxWidth, Tokens.Layout.sidebarWidth] {
            split.setPosition(width, ofDividerAt: 0)
            try await expectBoundary()
            #expect(abs(sidebar.frame.width - width) <= 1, "Calendar's sidebar must remain resizable")
        }
        app.calendar.date = .now.addingTimeInterval(-30 * 24 * 60 * 60)
        try await settle()
        try pressPageControl("calendar.today", in: window)
        #expect(app.calendar.calendar.isDateInToday(app.calendar.date), "Today must change the visible calendar date")
        let remainsWritable = app.calendar.calendars.contains { $0.canWrite }
        try #require(remainsWritable, "The fixture must still allow event creation")
        try pressPageControl("calendar.newEvent", in: window)
        #expect(app.calendar.editor != nil, "The page's New Event button must open the event editor")
        app.calendar.editor = nil
        await app.signOut()
    }

    @Test func attachmentToolbarClearsSidebarAndRestoresMail() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let suite = "AttachmentToolbarBoundary.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox).environment(app)
            .environment(\.workspaceToolbarID, workspaceToolbarIdentifier()).defaultAppStorage(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_280, height: 760))
        window.orderBack(nil)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        try await settleMail(in: controller.view, window: window)
        let mail = try mailSplit(in: controller.view)
        let mailPanes = mail.arrangedSubviews
        let mailWidths = mailPanes.map(\.frame.width)
        let mailFrames = mailPanes.map(\.frame)
        let retainedTables = tables(in: mail)
        let retainedScrolls = retainedTables.map(\.enclosingScrollView)
        let existingSplits = Set(descendants(in: controller.view).compactMap { $0 as? NSSplitView }.map(ObjectIdentifier.init))

        func openAttachments() async throws -> NSSplitView {
            mailbox.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)
            try await settle()
            // Calendar also contains a table, but only Attachments mounts a new split.
            let splits = descendants(in: controller.view).compactMap { $0 as? NSSplitView }.filter {
                $0.isVertical && !existingSplits.contains(ObjectIdentifier($0)) && !tables(in: $0).isEmpty
                    && !descendants(in: $0).contains { $0 is MailColumnProbe.ProbeView }
            }
            try #require(splits.count == 1)
            return try #require(splits.first)
        }

        func expectBoundary(_ split: NSSplitView, showsSidebar: Bool = true) async throws {
            try await settle()
            #expect(split.window === window)
            try expectDestinationControl(in: window)
            try #require(split.arrangedSubviews.count == (showsSidebar ? 2 : 1))
            let firstPane = try #require(split.arrangedSubviews.first)
            let frame = firstPane.convert(firstPane.bounds, to: nil)
            let railWidth = expectedRailWidth(in: window)
            let sidebarEdge = showsSidebar ? frame.maxX : railWidth
            for identifier in leadingToolbarIdentifiers(in: window) {
                let item = try #require(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == identifier })
                let view = try #require(item.view)
                let control = view.convert(view.bounds, to: nil)
                #expect(control.minX >= sidebarEdge - 1 && control.maxX <= window.frame.width + 1,
                    "\(identifier) must remain outside the Attachments sidebar and inside the window")
            }
            #expect(abs(frame.maxY - (window.contentLayoutRect.maxY - Tokens.Border.hairline)) <= 1,
                "Attachments must start below the toolbar without an extra gap: \(frame)")
            if !showsSidebar {
                #expect(abs(frame.minX - railWidth) <= 1 && abs(frame.maxX - window.frame.width) <= 1,
                    "Attachments must use the sidebar's space when it is hidden")
            }
        }

        var split = try await openAttachments()
        try await expectBoundary(split)
        for width in [Tokens.Layout.sidebarMinWidth, Tokens.Layout.sidebarMaxWidth] {
            split.setPosition(width, ofDividerAt: 0)
            try await expectBoundary(split)
            #expect(abs(try #require(split.arrangedSubviews.first).frame.width - width) <= 1,
                "The Attachments sidebar must remain resizable")
        }
        try await pressToolbarButton(in: window, identifier: "workspace.sidebar")
        try await expectBoundary(split, showsSidebar: false)
        try await pressToolbarButton(in: window, identifier: "workspace.sidebar")
        try await expectBoundary(split)
        #expect(abs(try #require(split.arrangedSubviews.first).frame.width - Tokens.Layout.sidebarMaxWidth) <= 1,
            "Showing the Attachments sidebar must restore its dragged width")
        app.destination = .calendar
        try await settle()
        app.destination = .mail
        split = try await openAttachments()
        try await expectBoundary(split)
        #expect(abs(try #require(split.arrangedSubviews.first).frame.width - Tokens.Layout.sidebarMaxWidth) <= 1,
            "Returning from Calendar must preserve the Attachments sidebar width")

        func expectMailRestored() async throws {
            // Compare at one fixed window size; native columns may resize with the window.
            mailbox.selectedMailbox = .combined(SystemLabel.inbox)
            try await settleMail(in: controller.view, window: window)
            // Populated tables can precede the deferred native divider restoration.
            let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            func originalGeometryReturned() -> Bool {
                zip(mailPanes, mailFrames).allSatisfy { pane, frame in
                    abs(pane.frame.minX - frame.minX) <= 1 && abs(pane.frame.minY - frame.minY) <= 1
                        && abs(pane.frame.width - frame.width) <= 1 && abs(pane.frame.height - frame.height) <= 1
                }
            }
            while !originalGeometryReturned(), ContinuousClock.now < restoreDeadline { try await settle() }
            #expect(originalGeometryReturned(), "Mail must restore its original pane frames after destination layout settles")
            #expect(try mailSplit(in: controller.view) === mail)
            #expect(mail.arrangedSubviews.map(ObjectIdentifier.init) == mailPanes.map(ObjectIdentifier.init),
                "Returning from Attachments must retain every native Mail pane")
            #expect(tables(in: mail).map(ObjectIdentifier.init) == retainedTables.map(ObjectIdentifier.init))
            for (table, scroll) in zip(retainedTables, retainedScrolls) {
                #expect(table.window === window && table.enclosingScrollView === scroll,
                    "Attachment navigation must keep Mail's native tables and scroll views attached")
            }
            for (pane, width) in zip(mailPanes, mailWidths) {
                #expect(abs(pane.frame.width - width) <= 1, "Returning from Attachments must restore Mail's pane widths")
            }
        }
        try await expectMailRestored()

        split = try await openAttachments()
        for width in [1_280, 1_079, 1_080, 1_081, 960, 720, 1_280] {
            window.setContentSize(NSSize(width: width, height: 760))
            let compact = CGFloat(width) - expectedRailWidth(in: window) < Tokens.Layout.sidebarCompactWidth
            try await expectBoundary(split, showsSidebar: !compact)
            if compact {
                var sidebarPopover = try await attachmentSidebarPopover(in: window)
                let table = try #require(sidebarPopover.contentView.flatMap { tables(in: $0).first })
                #expect(table.numberOfRows > 0, "The compact library sidebar must retain its native list")
                for identifier in ["attachments.sidebar.allAccounts", "attachments.sidebar.allCategories"] {
                    _ = try pageControl(identifier, in: sidebarPopover)
                }
                if width == Int(Tokens.Layout.windowMinWidth) {
                    let categoryID = "attachments.sidebar.category.\(AttachmentCategory.uncategorized.rawValue)"
                    try pressPageControl(categoryID, in: sidebarPopover)
                    try await waitForPopoverToClose(sidebarPopover)
                    #expect(mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID && app.destination == .mail,
                        "Choosing a file category must keep the attachment library open")
                    sidebarPopover = try await attachmentSidebarPopover(in: window)
                    #expect(try pageControl(categoryID, in: sidebarPopover).isSelected,
                        "The selected file category must survive closing and reopening navigation")
                    let account = try #require(mailbox.accounts.first?.account)
                    let accountID = "attachments.sidebar.account.\(account.id)"
                    try pressPageControl(accountID, in: sidebarPopover)
                    try await waitForPopoverToClose(sidebarPopover)
                    #expect(mailbox.selectedMailbox == .combined(AttachmentLibraryModel.mailboxID),
                        "File account scope must not change Mail's selected mailbox")
                    sidebarPopover = try await attachmentSidebarPopover(in: window)
                    #expect(try pageControl(accountID, in: sidebarPopover).isSelected)
                    #expect(try pageControl(categoryID, in: sidebarPopover).isSelected,
                        "Choosing an account must retain the file category")
                    try pressPageControl("attachments.sidebar.allCategories", in: sidebarPopover)
                    try await waitForPopoverToClose(sidebarPopover)
                    sidebarPopover = try await attachmentSidebarPopover(in: window)
                    #expect(try pageControl(accountID, in: sidebarPopover).isSelected,
                        "All categories must retain the chosen account")
                    try pressPageControl("attachments.sidebar.allAccounts", in: sidebarPopover)
                    try await waitForPopoverToClose(sidebarPopover)
                    sidebarPopover = try await attachmentSidebarPopover(in: window)
                    #expect(try pageControl("attachments.sidebar.allAccounts", in: sidebarPopover).isSelected)
                    #expect(try pageControl("attachments.sidebar.allCategories", in: sidebarPopover).isSelected)
                }
                try await pressToolbarButton(in: window, identifier: "workspace.sidebar")
                try await waitForPopoverToClose(sidebarPopover)
            }
        }
        #expect(abs(try #require(split.arrangedSubviews.first).frame.width - Tokens.Layout.sidebarMaxWidth) <= 1,
            "Widening the window must restore the Attachments sidebar's dragged width")
        try await expectMailRestored()
        await app.signOut()
    }

    @Test func workspaceKeepsFirstRowsAndMailSearchVisible() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !mailbox.hasSyncedOnce, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(mailbox.hasSyncedOnce)
        // The mailbox heading remains; the optional quick-filter band is disabled.
        let quickFilters = mailbox.listPreferences.showsQuickFilters
        mailbox.listPreferences.showsQuickFilters = false
        defer { mailbox.listPreferences.showsQuickFilters = quickFilters }
        let suite = "SidebarLayoutTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set("", forKey: SidebarExpansion.storageKey)
        defer { settings.removePersistentDomain(forName: suite) }

        let toolbarIdentifier = workspaceToolbarIdentifier()
        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox).environment(app)
            .environment(\.workspaceToolbarID, toolbarIdentifier).defaultAppStorage(settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }

        // At 960 points every section uses the folded Search button.
        let configurations: [(CGFloat, NSWindow.ToolbarStyle, Bool)] = [
            (1_280, .unified, false), (960, .unified, true), (960, .unifiedCompact, true), (1_280, .unified, false)
        ]
        for (width, toolbarStyle, searchFolds) in configurations {
            window.toolbarStyle = toolbarStyle
            window.setContentSize(NSSize(width: width, height: 760))
            try await settleMail(in: controller.view, window: window)
            try await expectMailVisible(in: controller.view, window: window, mailboxTitle: mailbox.selectedLabelTitle, searchFolds: searchFolds)
        }
        try await expectSidebarGutterDrags(in: controller.view, window: window)
        // Below the three column minimums the sidebar steps aside, and it comes back with the room.
        window.setContentSize(NSSize(width: Tokens.Layout.windowMinWidth, height: 760))
        try await expectColumnsFit(in: controller.view, window: window, sidebarCollapsed: true)
        try expectLeadingEdgeVisible(in: controller.view, label: "\(Int(Tokens.Layout.windowMinWidth)) points")
        window.setContentSize(NSSize(width: 1_280, height: 760))
        try await expectColumnsFit(in: controller.view, window: window, sidebarCollapsed: false)
        try await settleMail(in: controller.view, window: window)
        try await expectMailVisible(in: controller.view, window: window, mailboxTitle: mailbox.selectedLabelTitle, searchFolds: false)
        // Opening the assistant widens a window too narrow for the list and reader
        // beside it, and the window keeps that width while the assistant shows.
        window.setContentSize(NSSize(width: Tokens.Layout.windowMinWidth, height: 760))
        try await settle()
        try await toggleAssistant(in: window, rootView: controller.view, opens: true)
        try await settle()
        try await expectColumnsBesideAssistant(in: controller.view, window: window, label: "opening at 720 points")
        for width in [CGFloat(960), 1_079, 1_080, 1_081, Tokens.Layout.windowMinWidth] {
            window.setContentSize(NSSize(width: width, height: 760))
            try await settle()
            try await settle()
            try await expectColumnsBesideAssistant(in: controller.view, window: window, label: "\(Int(width)) points")
        }
        window.setContentSize(NSSize(width: 1_280, height: 760))
        try await settle()
        try await toggleAssistant(in: window, rootView: controller.view, opens: false)
        app.destination = .calendar
        try await settle()
        app.destination = .mail
        try await settleMail(in: controller.view, window: window)
        try await expectMailVisible(in: controller.view, window: window, mailboxTitle: mailbox.selectedLabelTitle, searchFolds: false)
        await app.signOut()
    }

    private func expectSidebarGutterDrags(in rootView: NSView, window: NSWindow) async throws {
        let probe = try #require(descendants(in: rootView).compactMap { $0 as? MailColumnProbe.ProbeView }
            .first { $0.pane == .navigation })
        let divider = try #require(EnclosingSplitDivider(of: probe))
        let originalPosition = divider.pane.frame.maxX
        defer { divider.split.setPosition(originalPosition, ofDividerAt: divider.index) }
        // Start between the limits so the same check covers widening and narrowing.
        divider.split.setPosition(Tokens.Layout.sidebarWidth + Tokens.Layout.columnGutter, ofDividerAt: divider.index)
        try await settle()
        let handle = try #require(descendants(in: divider.pane).compactMap { $0 as? DividerGrabView }.first)
        let frameView = try #require(window.contentView?.superview)
        for fraction in [CGFloat(0.25), 0.5, 0.75] {
            let point = handle.convert(NSPoint(x: handle.bounds.width * fraction, y: handle.bounds.height * fraction), to: nil)
            let hit = frameView.hitTest(point)
            // AppKit's native divider hit area overlaps the gutter's outer edge.
            #expect(hit === handle || hit === divider.split, "Sidebar content intercepts the resize gutter at \(point)")
        }
        for distance in [CGFloat(32), -64] {
            let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
            let target = try #require(frameView.hitTest(start) as? DividerGrabView,
                "The sidebar gutter must receive the initial mouse press")
            let initialPosition = divider.pane.frame.maxX
            let end = NSPoint(x: start.x + distance, y: start.y)
            func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            }
            // Deliver to the view found by the window's hit test, as a mouse drag does.
            target.mouseDown(with: try event(.leftMouseDown, at: start))
            target.mouseDragged(with: try event(.leftMouseDragged, at: end))
            target.mouseUp(with: try event(.leftMouseUp, at: end))
            try await settle()
            #expect(abs(divider.pane.frame.maxX - initialPosition - distance) <= 1,
                "Dragging the sidebar gutter must move its divider by \(distance) points")
            #expect(divider.pane.frame.width >= Tokens.Layout.sidebarMinWidth + Tokens.Layout.columnGutter - 1)
            #expect(divider.pane.frame.width <= Tokens.Layout.sidebarMaxWidth + Tokens.Layout.columnGutter + 1)
        }
        divider.split.setPosition(originalPosition, ofDividerAt: divider.index)
        try await settle()
    }

    private func expectMailVisible(in rootView: NSView, window: NSWindow, mailboxTitle: String, searchFolds: Bool) async throws {
        let width = window.frame.width
        let probes = descendants(in: rootView).compactMap { $0 as? MailColumnProbe.ProbeView }
        let mailTables = probes.flatMap { probe -> [NSTableView] in
            var child: NSView = probe
            while let parent = child.superview {
                if let split = parent as? NSSplitView, split.isVertical {
                    return split.isSubviewCollapsed(child) ? [] : tables(in: child)
                }
                child = parent
            }
            return []
        }.sorted {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        try #require(mailTables.count == 2)
        for table in mailTables {
            let scroll = try #require(table.enclosingScrollView)
            scrollToTop(scroll)
        }
        try await settle()
        let markers = descendants(in: rootView).compactMap { $0 as? AuditLayoutBounds.BoundaryView }
        func headerFrame(_ identifier: String) throws -> NSRect {
            let matches = markers.filter { $0.identifier?.rawValue == identifier && $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            try #require(matches.count == 1, "The audit must measure exactly one native \(identifier) boundary")
            let marker = try #require(matches.first)
            let frame = marker.convert(marker.bounds, to: nil)
            try #require(!frame.isEmpty && window.contentLayoutRect.insetBy(dx: -1, dy: -1).contains(frame),
                "The complete \(identifier) must remain visible: \(frame), content layout \(window.contentLayoutRect)")
            return frame
        }
        let heading = try headerFrame("mail.list.heading")
        let messageHeader = try headerFrame("mail.list.header")
        let sidebarHeader = try headerFrame("mail.sidebar.heading")
        let headings = WorkspaceAuditAccessibility.elements(in: rootView).filter { $0.role == "AXHeading" }
        let title = headings.first {
            $0.label == mailboxTitle && $0.isVisible(in: window) && heading.insetBy(dx: -1, dy: -1).contains($0.frame(in: window))
        }
        if title == nil {
            print("Mailbox title lookup at \(width), heading \(heading): \(headings.map { $0.diagnosticDescription(in: window) })")
        }
        let visibleTitle = try #require(title, "The actual mailbox title must remain an accessible heading inside its padded header")
        #expect(visibleTitle.hasHitTarget(in: window), "The mailbox heading must be unobscured")
        #expect(messageHeader.insetBy(dx: -1, dy: -1).contains(heading),
            "The mailbox heading must remain inside the message-list header")
        for header in [sidebarHeader, messageHeader] {
            #expect(abs(header.maxY - window.contentLayoutRect.maxY) <= 1,
                "Page headers must start directly below the toolbar: \(header)")
        }
        // AppKit keeps each scroll view beneath its safe-area header. Compare
        // rows with the measured header edge, not the scroll view's outer frame.
        for (index, table) in mailTables.enumerated() {
            try #require(table.numberOfRows > 0)
            let row = table.convert(table.rect(ofRow: 0), to: nil)
            #expect(row.maxY <= window.contentLayoutRect.maxY + 1, "First row is covered by the toolbar at width \(width)")
            let expectedTop = index == 0 ? sidebarHeader.minY : messageHeader.minY
            #expect(row.maxY <= expectedTop + 1, "The first message row must clear the mailbox heading")
            #expect(row.maxY >= expectedTop - Tokens.Space.s4, "The toolbar or heading inset must not be counted twice")
            #expect(row.minY >= window.contentLayoutRect.minY - 1)
            #expect(row.minX >= -1 && row.maxX <= window.frame.width + 1)
            let point = NSPoint(x: row.midX, y: row.midY)
            let hit = window.contentView?.superview?.hitTest(point)
            #expect(hit?.isDescendant(of: table) == true || hit === table,
                "The first row must receive clicks below the page heading")
        }
        let frameView = try #require(window.contentView?.superview)
        let fields = descendants(in: frameView).compactMap { $0 as? NSSearchField }
            .filter { $0.placeholderString == "Search mail" && !$0.isHiddenOrHasHiddenAncestor }
        let searchItems = window.toolbar?.visibleItems?.filter { $0.itemIdentifier.rawValue.contains("workspace.search") } ?? []
        #expect(searchItems.count == 1, "Mail search must remain in the visible toolbar at width \(width)")
        // An idle search folds into a button that opens the field.
        #expect(fields.count == (searchFolds ? 0 : 1), "Search field at width \(width)")
        for field in fields {
            let bounds = field.convert(field.bounds, to: nil)
            #expect(!field.isHiddenOrHasHiddenAncestor)
            #expect(bounds.width >= Tokens.Layout.searchMinWidth - 1)
            #expect(bounds.minX >= 0 && bounds.maxX <= window.frame.width + 1)
            #expect(bounds.minY >= window.contentLayoutRect.maxY - 1)
        }
    }

    /// Waits for the sidebar column to reach the expected state, then checks
    /// that every visible column lies inside the window.
    private func expectColumnsFit(in rootView: NSView, window: NSWindow, sidebarCollapsed: Bool) async throws {
        let width = window.frame.width
        let probe = try #require(descendants(in: rootView)
            .compactMap { $0 as? MailColumnProbe.ProbeView }
            .first { $0.pane == .navigation })
        var sidebar: NSView = probe
        var split: NSSplitView?
        while let parent = sidebar.superview {
            if let parent = parent as? NSSplitView, parent.isVertical {
                split = parent
                break
            }
            sidebar = parent
        }
        let columns = try #require(split)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while columns.isSubviewCollapsed(sidebar) != sidebarCollapsed, ContinuousClock.now < deadline {
            try await settle()
        }
        #expect(columns.isSubviewCollapsed(sidebar) == sidebarCollapsed, "Sidebar collapsed state at width \(width)")
        try await settle()
        for column in columns.arrangedSubviews where !columns.isSubviewCollapsed(column) {
            let frame = column.convert(column.bounds, to: nil)
            #expect(frame.minX >= -1 && frame.maxX <= width + 1, "A column runs past the window at width \(width)")
        }
    }

    /// The first layout fills the lists and reserves the toolbar inset a few
    /// hundred milliseconds after the window appears, later under load.
    private func settleMail(in rootView: NSView, window: NSWindow) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            try await settle()
            let tables = tables(in: rootView)
            let filled = tables.count >= 2 && tables.allSatisfy { $0.numberOfRows > 0 }
            let inset = tables.allSatisfy { table in
                guard let scroll = table.enclosingScrollView else { return false }
                return scroll.safeAreaInsets.top > 0 || scroll.convert(scroll.bounds, to: nil).maxY <= window.contentLayoutRect.maxY + 1
            }
            if filled, inset { return }
        } while ContinuousClock.now < deadline
    }

    private func mailSplit(in rootView: NSView) throws -> NSSplitView {
        let probe = try #require(descendants(in: rootView).first { $0 is MailColumnProbe.ProbeView })
        return try #require(EnclosingSplitDivider(of: probe)?.split)
    }

    private func expectLeadingEdgeVisible(in rootView: NSView, label: String) throws {
        let split = try mailSplit(in: rootView)
        #expect(split.convert(split.bounds, to: nil).minX >= -1, "The mail split starts off screen at \(label)")
        let panes = split.arrangedSubviews.filter { !$0.isHidden && !split.isSubviewCollapsed($0) }
        for table in panes.flatMap(tables(in:)) where table.numberOfRows > 0 {
            #expect(table.convert(table.rect(ofRow: 0), to: nil).minX >= -1, "A first row starts off screen at \(label)")
        }
    }

    /// Checks that the window has room for the list and reader beside the
    /// assistant, which keeps its minimum width at these sizes, and that no
    /// mail column runs under it.
    private func expectColumnsBesideAssistant(in rootView: NSView, window: NSWindow, label: String) async throws {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(3))
        var split = try mailSplit(in: rootView)
        func fits() -> Bool {
            let panes = split.arrangedSubviews.filter { !$0.isHidden && !split.isSubviewCollapsed($0) }
            let assistantEdge = window.frame.width - Tokens.Assistant.sidebarMinWidth
            return window.frame.width >= AssistantSidebarLayout.windowMinimum - 1
                && split.convert(split.bounds, to: nil).minX >= -1
                && panes.allSatisfy { $0.convert($0.bounds, to: nil).maxX <= assistantEdge + 1 }
                && panes.flatMap(tables(in:)).filter { $0.numberOfRows > 0 }.allSatisfy {
                    $0.convert($0.rect(ofRow: 0), to: nil).minX >= -1
                }
        }
        // Clamping a requested window width and collapsing native columns can
        // finish in separate passes. Wait for the same final bounds asserted
        // below, rather than assuming two fixed sleeps cover both passes.
        while !fits(), ContinuousClock.now < deadline {
            try await settle()
            split = try mailSplit(in: rootView)
        }
        let elapsed = started.duration(to: .now)
        if elapsed > .milliseconds(400) {
            let frames = split.arrangedSubviews.filter { !$0.isHidden && !split.isSubviewCollapsed($0) }.map(\.frame)
            print("Sidebar assistant layout \(label): \(fits() ? "settled" : "still invalid") after \(elapsed); window width \(window.frame.width), split \(split.frame), columns \(frames)")
        }
        #expect(window.frame.width >= AssistantSidebarLayout.windowMinimum - 1,
            "The window is \(window.frame.width) points wide after \(label) with the assistant")
        let assistantEdge = window.frame.width - Tokens.Assistant.sidebarMinWidth
        for column in split.arrangedSubviews where !column.isHidden && !split.isSubviewCollapsed(column) {
            #expect(column.convert(column.bounds, to: nil).maxX <= assistantEdge + 1,
                "A mail column runs under the assistant after \(label)")
        }
        try expectLeadingEdgeVisible(in: rootView, label: "\(label) with the assistant")
    }

    /// Clicks the assistant button and waits for the mail split to give the
    /// assistant room or take the room back. Under load a click can land
    /// while the toolbar still replaces its items after a resize and do
    /// nothing, so a click that changes nothing within three seconds is sent
    /// once more.
    private func toggleAssistant(in window: NSWindow, rootView: NSView, opens: Bool) async throws {
        // The rail occupies window space even when the assistant is closed.
        func isOpen() throws -> Bool {
            try mailSplit(in: rootView).frame.width < window.frame.width - expectedRailWidth(in: window) - Tokens.Border.hairline
        }
        for _ in 0..<2 {
            guard try isOpen() != opens else { break }
            try await pressToolbarButton(in: window, identifier: "workspace.assistant")
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            repeat { try await settle() } while try isOpen() != opens && ContinuousClock.now < deadline
        }
        let state = "\(try mailSplit(in: rootView).frame.width)-point split in a \(window.frame.width)-point window"
        #expect(try isOpen() == opens, "The assistant didn't \(opens ? "open" : "close"): \(state)")
    }

    private func pressToolbarButton(in window: NSWindow, identifier: String) async throws {
        // Hosted tests cannot require foreground activation. Press the rendered
        // button through AppKit accessibility after checking it can be hit.
        var target: NSView?
        var seen = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while target == nil, ContinuousClock.now < deadline {
            let item = window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == identifier }
            if let item, let view = item.view, view.window === window {
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                let hit = window.contentView?.superview?.hitTest(point)
                if hit?.isDescendant(of: view) == true { target = view }
                seen = "visible \(item.isVisible) point \(point) hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")"
            } else {
                seen = "visible \(item?.isVisible ?? false) view in window \(item?.view?.window === window)"
            }
            if target == nil { try await settle() }
        }
        let view = try #require(target, "The \(identifier) button can't be clicked: \(seen)")
        var visited: Set<ObjectIdentifier> = []
        func press(_ value: Any) -> Bool {
            guard let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return false }
            func property(_ key: String) -> Any? {
                object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
            }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if property("accessibilityRole") as? String == NSAccessibility.Role.button.rawValue,
               object.responds(to: selector), let implementation = object.method(for: selector) {
                // SwiftUI AX nodes expose this public BOOL selector without
                // declaring formal NSAccessibility protocol conformance.
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                if unsafeBitCast(implementation, to: Press.self)(object, selector) { return true }
            }
            let children = property("accessibilityChildren") as? [Any] ?? []
            return (children + NSAccessibility.unignoredChildren(from: children)).contains(where: press)
        }
        try #require(descendants(in: view).contains(where: press), "The rendered \(identifier) button must support accessibility Press")
    }

    private func expectCalendarPageControls(in window: NSWindow) throws {
        for identifier in ["calendar.today", "calendar.goToDate", "calendar.newEvent"] {
            _ = try pageControl(identifier, in: window)
        }
        let mode = try #require(WorkspaceAuditAccessibility.matching("calendar.viewMode", in: window).first,
            "Calendar view selection must remain visible in the page header")
        #expect(mode.hasHitTarget(in: window), "Calendar view selection must receive clicks")
    }

    private func pageControl(_ identifier: String, in window: NSWindow) throws -> WorkspaceAuditAccessibility.Element {
        let candidate = WorkspaceAuditAccessibility.matching(identifier, in: window).first { $0.supportsPress }
        if candidate == nil, identifier.hasPrefix("calendar."), let root = window.contentView {
            let controls = WorkspaceAuditAccessibility.elements(in: root).filter {
                $0.identifier?.hasPrefix("calendar.") == true || $0.label == "New Event"
            }
            print("Calendar control lookup \(identifier): \(controls.map { $0.diagnosticDescription(in: window) })")
        }
        let control = try #require(candidate,
            "The visible \(identifier) control must support accessibility Press")
        try #require(control.hasHitTarget(in: window), "The \(identifier) control must have an unobscured hit target")
        return control
    }

    private func pressPageControl(_ identifier: String, in window: NSWindow) throws {
        let control = try pageControl(identifier, in: window)
        try #require(control.press(), "The \(identifier) control must activate: \(control.diagnosticDescription(in: window))")
    }

    private func attachmentSidebarPopover(in window: NSWindow) async throws -> NSWindow {
        let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        try await pressToolbarButton(in: window, identifier: "workspace.sidebar")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var popover: NSWindow?
        repeat {
            try await settle()
            popover = NSApp.windows.first {
                $0.isVisible && !visibleWindows.contains(ObjectIdentifier($0))
                    && !WorkspaceAuditAccessibility.matching("attachments.sidebar.allAccounts", in: $0).isEmpty
            }
        } while popover == nil && ContinuousClock.now < deadline
        return try #require(popover, "The compact sidebar button must open attachment account and category navigation")
    }

    private func waitForPopoverToClose(_ popover: NSWindow) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat { try await settle() } while popover.isVisible && ContinuousClock.now < deadline
        #expect(!popover.isVisible, "Selecting a file scope or toggling navigation must close the compact sidebar")
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    /// AppKit mirrors item changes across toolbars that share an identifier,
    /// and the test host's own mail window already uses the workspace one.
    private func workspaceToolbarIdentifier() -> String {
        "\(MailWindowPreferences.toolbarID).\(UUID().uuidString)"
    }

    private func expectedRailWidth(in window: NSWindow) -> CGFloat {
        window.contentLayoutRect.width >= Tokens.Workspace.railBreakpoint ? Tokens.Workspace.railWidth : 0
    }

    private func leadingToolbarIdentifiers(in window: NSWindow, section: WorkspaceSection = .mail) -> [String] {
        ["workspace.sidebar"] + (expectedRailWidth(in: window) == 0 ? ["workspace.destination"] : [])
            + (section == .calendar ? [] : ["mail.compose"])
    }

    private func expectDestinationControl(in window: NSWindow) throws {
        let item = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "workspace.destination" },
            "The compact destination control must retain its toolbar identity")
        let showsRail = expectedRailWidth(in: window) > 0
        #expect(item.isHidden == showsRail, "Only one global destination control should be visible")
        if !showsRail {
            #expect(window.toolbar?.visibleItems?.contains { $0 === item } == true,
                "Compact windows must keep the destination control out of overflow")
        }
    }

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
        settings.set("", forKey: SidebarExpansion.storageKey)
        defer { settings.removePersistentDomain(forName: suite) }

        let toolbarIdentifier = workspaceToolbarIdentifier()
        let controller = NSHostingController(rootView: MainView(mailbox: mailbox).environment(app)
            .environment(\.workspaceToolbarID, toolbarIdentifier).defaultAppStorage(settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        // The hosting controller shrinks the window to its minimum, where the
        // sidebar steps aside for the list and reader.
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }
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
        settings.set(SystemLabel.inbox, forKey: SidebarExpansion.storageKey)
        try await settle()
        let account = try #require(mailbox.accounts.first?.account)
        _ = try await selectRow(in: table, matching: .account(account.id, SystemLabel.inbox), mailbox: mailbox)
        #expect(mailbox.selectedMailbox == .account(account.id, SystemLabel.inbox))
        settings.set("", forKey: SidebarExpansion.storageKey)
        try await settle()

        // Alternate populated and empty mailboxes, including the Outbox's own List.
        var expanded = Set<String>()
        for id in [MailboxModel.snoozedID, SystemLabel.spam, SystemLabel.trash,
                   MailboxModel.snoozedID, SystemLabel.trash, MailboxModel.snoozedID,
                   SystemLabel.draft, MailboxModel.outboxID, SystemLabel.inbox,
                   MailboxModel.outboxID, SystemLabel.inbox] {
            mailbox.selectedMailbox = .combined(id)
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            settings.set(SidebarExpansion(ids: expanded).rawValue, forKey: SidebarExpansion.storageKey)
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

    @Test func categoriesRemainReachableWithoutAnInboxFavorite() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !mailbox.hasSyncedOnce, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(mailbox.hasSyncedOnce)
        let account = try #require(mailbox.accounts.first?.account)
        if let favorite = mailbox.navigation.favorites.first(where: { $0.target == .mailbox(labelID: SystemLabel.inbox, scope: .allAccounts) }) {
            await mailbox.navigation.removeFavorite(favorite.id)
        }
        await mailbox.setCategory(.promotions, enabled: true, accountID: account.id)
        let suite = "SidebarCategoryTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set(SystemLabel.inbox, forKey: SidebarExpansion.storageKey)
        defer { settings.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: SidebarView(mailbox: mailbox).environment(app).defaultAppStorage(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Tokens.Layout.sidebarWidth, height: Tokens.Layout.windowHeight),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        try await settle()
        let table = try #require(tables(in: controller.view).first)
        let category = MailboxID.account(account.id, InboxCategory.promotions.labelID)
        _ = try await selectRow(in: table, matching: category, mailbox: mailbox)
        #expect(mailbox.selectedMailbox == category)

        mailbox.applyAccountPresentation(preferences: Array(mailbox.accountPresentation.values), visibleAccountIDs: [account.id])
        try await settle()
        let singleAccountTable = try #require(tables(in: controller.view).first)
        _ = try await selectRow(in: singleAccountTable, matching: category, mailbox: mailbox)
        #expect(mailbox.selectedMailbox == category)
        await app.signOut()
    }

    private func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }

    private func selectRow(in table: NSTableView, matching mailboxID: MailboxID, mailbox: MailboxModel) async throws -> Int {
        // Probe native selection tags so sections inserted before Mailboxes do
        // not change which rows this test selects. An empty native selection
        // sends no deselection callback, so reset the model too. The next
        // native selection must update the optional MailboxID from nil.
        // Account/profile changes may still insert rows during the first layout.
        var index = 0
        while index < table.numberOfRows {
            table.deselectAll(nil)
            mailbox.selectedMailbox = nil
            try await settle()
            try #require(mailbox.selectedMailbox == nil)
            try #require(table.selectedRow == -1)
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try await settle()
            if mailbox.selectedMailbox == mailboxID { return index }
            index += 1
        }
        throw SidebarSelectionError.mailboxNotFound(mailboxID)
    }

    private enum SidebarSelectionError: Error { case mailboxNotFound(MailboxID) }

    private func scrollToTop(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        var bounds = clip.bounds
        // Extreme coordinates lose the top inset when AppKit constrains bounds.
        bounds.origin.y = (scroll.documentView?.frame.minY ?? 0) - scroll.contentInsets.top
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Toolbar spaces ignore hidden(_:), so the mail toolbar's spaces stay in
    /// Calendar and the attachment library, and only the item order keeps them
    /// ahead of those sections' controls. In Mail, More once had a group of
    /// its own, and its space stayed before Search after narrow windows folded
    /// it into a menu. The library's controls once pushed Search into the
    /// overflow menu at the minimum window width.
    @Test func sectionToolbarsKeepTheirSpacingAndSearch() async throws {
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
        settings.set("", forKey: SidebarExpansion.storageKey)
        defer { settings.removePersistentDomain(forName: suite) }

        let toolbarIdentifier = workspaceToolbarIdentifier()
        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox).environment(app)
            .environment(\.workspaceToolbarID, toolbarIdentifier).defaultAppStorage(settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }
        app.destination = .mail
        mailbox.selectedMailbox = .combined(AttachmentLibraryModel.mailboxID)

        // Window resizing can change the native sidebar width. Leading controls
        // follow its edge; trailing controls retain their window positions.
        var sharedFrames: [Int: [String: NSRect]] = [:]
        var sharedDiagnostics: [Int: [String: String]] = [:]
        func describe(_ view: NSView) -> String {
            let buttons = descendants(in: view).compactMap { $0 as? NSButton }.map {
                "\(type(of: $0)) frame=\($0.convert($0.bounds, to: nil)) fitting=\($0.fittingSize)"
            }
            return "\(type(of: view)) frame=\(view.convert(view.bounds, to: nil)) fitting=\(view.fittingSize) intrinsic=\(view.intrinsicContentSize) buttons=\(buttons)"
        }
        func expectSharedPositions() async throws {
            try await settle()
            #expect(window.toolbar?.identifier == toolbarIdentifier, "Hosted toolbar state must stay separate from other windows")
            let width = Int(window.frame.width)
            try expectDestinationControl(in: window)
            let section: WorkspaceSection = app.destination == .calendar ? .calendar
                : mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID ? .attachments : .mail
            let identifiers = leadingToolbarIdentifiers(in: window, section: section)
                + ["workspace.search", "workspace.tasks", "workspace.assistant"]
            if sharedFrames[width] == nil {
                // Toolbar membership settles before its native backing views finish sizing.
                // Record the baseline only after all measured frames stop changing.
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var previous: [String: NSRect] = [:]
                var unchangedSince = ContinuousClock.now
                var settled = false
                repeat {
                    window.contentView?.superview?.layoutSubtreeIfNeeded()
                    var current: [String: NSRect] = [:]
                    for identifier in identifiers {
                        if let view = window.toolbar?.visibleItems?.first(where: { $0.itemIdentifier.rawValue == identifier })?.view,
                           view.window === window {
                            current[identifier] = view.convert(view.bounds, to: nil)
                        }
                    }
                    if current != previous || current.count != identifiers.count {
                        previous = current
                        unchangedSince = .now
                    } else if unchangedSince.duration(to: .now) >= .milliseconds(200) {
                        settled = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                } while ContinuousClock.now < deadline
                try #require(settled, "The initial shared toolbar frames must settle at \(width) points: \(previous)")
            }
            var frames: [String: NSRect] = [:]
            var diagnostics: [String: String] = [:]
            for identifier in identifiers {
                let item = try #require(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == identifier },
                    "Shared control \(identifier) must remain visible at \(width) points")
                let view = try #require(item.view)
                let frame = view.convert(view.bounds, to: nil)
                frames[identifier] = frame
                diagnostics[identifier] = describe(view)
                let followsSidebar = ["workspace.sidebar", "workspace.destination", "mail.compose"].contains(identifier)
                if let baseline = sharedFrames[width], let expected = baseline[identifier] {
                    let origin = followsSidebar ? try #require(frames["workspace.sidebar"]).minX : 0
                    let expectedOrigin = followsSidebar ? try #require(baseline["workspace.sidebar"]).minX : 0
                    #expect(abs((frame.minX - origin) - (expected.minX - expectedOrigin)) <= 1
                        && abs((frame.maxX - origin) - (expected.maxX - expectedOrigin)) <= 1,
                        "\(identifier) moved from \(expected) to \(frame) when switching views at \(width) points; baseline \(sharedDiagnostics[width]?[identifier] ?? "unknown"); current \(diagnostics[identifier] ?? "unknown")")
                }
            }
            let split = try mailSplit(in: controller.view)
            let sidebar = try #require(split.arrangedSubviews.first)
            let sidebarEdge = split.isSubviewCollapsed(sidebar) ? 0 : sidebar.convert(sidebar.bounds, to: nil).maxX
            #expect(try #require(frames["workspace.sidebar"]).minX >= sidebarEdge - 1,
                "The leading toolbar controls must clear the current native sidebar")
            if sharedFrames[width] == nil {
                sharedFrames[width] = frames
                sharedDiagnostics[width] = diagnostics
            }
        }

        try await expectToolbar(
            in: window, width: 1_280, section: "library.", spacesAfter: ["library.sort"],
            hiding: ["library.compactOptions"]
        )
        try await expectSharedPositions()
        try await expectToolbar(in: window, width: 960, section: "library.",
            spacesAfter: ["library.compactOptions"], hiding: ["library.viewMode", "library.sort"])
        try await expectSharedPositions()
        // Narrow toolbars fold the layout and sort controls into one menu, as the mail actions fold.
        try await expectToolbar(
            in: window, width: Tokens.Layout.windowMinWidth, section: "library.",
            spacesAfter: ["library.compactOptions"], hiding: ["library.viewMode", "library.sort"]
        )
        try await expectSharedPositions()
        app.destination = .calendar
        for width in [CGFloat(1_280), 960, Tokens.Layout.windowMinWidth] {
            window.setContentSize(NSSize(width: width, height: 760))
            try await settle()
            try expectCalendarPageControls(in: window)
            let visible = window.toolbar?.visibleItems?.filter { !$0.isHidden }.map(\.itemIdentifier.rawValue) ?? []
            #expect(visible.contains("workspace.search"), "Calendar search must stay out of toolbar overflow")
            #expect(!visible.contains("mail.compose") && !visible.contains { $0.hasPrefix("calendar.") },
                "Calendar's page commands must not be duplicated in the default toolbar")
            try await expectSharedPositions()
        }
        app.destination = .mail
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        try await expectToolbar(
            in: window, width: 1_280, section: "mail.", spacesAfter: ["mail.trash", "mail.more", "mail.forward"],
            hiding: ["mail.compactActions", "mail.compactReplies"]
        )
        try await expectSharedPositions()
        try await expectToolbar(
            in: window, width: 960, section: "mail.", spacesAfter: ["mail.trash", "mail.compactActions", "mail.compactReplies"],
            hiding: ["mail.more"]
        )
        try await expectSharedPositions()
        try await expectToolbar(in: window, width: Tokens.Layout.windowMinWidth, section: "mail.",
            spacesAfter: ["mail.trash", "mail.compactActions", NSToolbarItem.Identifier.space.rawValue],
            hiding: ["mail.more", "mail.compactReplies"])
        try await expectSharedPositions()
        await app.signOut()
    }

    /// Waits for the toolbar to settle at `width`, then checks that Search is
    /// visible and which of the section's items a space follows, from the
    /// section's first item to Search. SwiftUI shows and hides items over
    /// several passes after a change. Other sections' items are left out,
    /// since SwiftUI sometimes leaves them in `visibleItems` long after a switch.
    private func expectToolbar(
        in window: NSWindow, width: CGFloat, section prefix: String,
        spacesAfter expected: [String], hiding hidden: Set<String> = []
    ) async throws {
        window.setContentSize(NSSize(width: width, height: 760))
        let space = NSToolbarItem.Identifier.space.rawValue
        // Search has a second space after the final action group.
        let expectedBeforeSpaces = expected + [space]
        let search = "workspace.search"
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var visible: [String] = []
        var beforeSpaces: [String] = []
        func settled() -> Bool {
            beforeSpaces == expectedBeforeSpaces && visible.contains(search) && hidden.isDisjoint(with: visible)
        }
        repeat {
            try await settle()
            visible = window.toolbar?.visibleItems?.map(\.itemIdentifier.rawValue) ?? []
            let sectionItems = visible
                .filter { $0.hasPrefix(prefix) || $0 == space || $0 == search }
                .drop(while: { !$0.hasPrefix(prefix) })
                .prefix(while: { $0 != search })
            beforeSpaces = zip(sectionItems, sectionItems.dropFirst()).compactMap { $1 == space ? $0 : nil }
        } while !settled() && ContinuousClock.now < deadline
        #expect(beforeSpaces == expectedBeforeSpaces, "Items before each space at width \(Int(width)): \(visible)")
        #expect(visible.contains(search), "Search must stay out of the overflow menu at width \(Int(width)): \(visible)")
        #expect(hidden.isDisjoint(with: visible), "Hidden items shown at width \(Int(width)): \(visible)")
    }

    private func settle() async throws {
        // Allow SwiftUI updates and the asynchronous mailbox observation to lay out.
        try await Task.sleep(for: .milliseconds(200))
    }
}
