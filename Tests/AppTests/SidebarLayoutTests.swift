import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct SidebarLayoutTests {
    @Test func calendarToolbarClearsSidebar() async throws {
        let app = AppModel()
        await app.start()
        await app.calendar.seedCalendarAudit()
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
            if window.frame.width < Tokens.Calendar.compactWidth {
                #expect(split.arrangedSubviews.count == 1)
                let content = try #require(split.arrangedSubviews.last)
                #expect(abs(content.convert(content.bounds, to: nil).minX) <= 1)
            } else {
                try #require(split.arrangedSubviews.count == 2)
                let sidebar = try #require(split.arrangedSubviews.first)
                let frame = sidebar.convert(sidebar.bounds, to: nil)
                for identifier in ["workspace.sidebar", "workspace.destination", "mail.compose"] {
                    let item = try #require(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == identifier })
                    let view = try #require(item.view)
                    #expect(view.convert(view.bounds, to: nil).minX >= frame.maxX - 1,
                        "\(identifier) must remain outside Calendar's sidebar")
                }
                #expect(abs(frame.maxY - (window.contentLayoutRect.maxY - Tokens.Border.hairline)) <= 1,
                    "Calendar's sidebar must start below the toolbar without an extra gap: \(frame)")
            }
        }

        for width in [1_280, 960, 720, 1_280] {
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
            try #require(split.arrangedSubviews.count == (showsSidebar ? 2 : 1))
            let firstPane = try #require(split.arrangedSubviews.first)
            let frame = firstPane.convert(firstPane.bounds, to: nil)
            let sidebarEdge = showsSidebar ? frame.maxX : 0
            for identifier in ["workspace.sidebar", "workspace.destination", "mail.compose"] {
                let item = try #require(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == identifier })
                let view = try #require(item.view)
                let control = view.convert(view.bounds, to: nil)
                #expect(control.minX >= sidebarEdge - 1 && control.maxX <= window.frame.width + 1,
                    "\(identifier) must remain outside the Attachments sidebar and inside the window")
            }
            #expect(abs(frame.maxY - (window.contentLayoutRect.maxY - Tokens.Border.hairline)) <= 1,
                "Attachments must start below the toolbar without an extra gap: \(frame)")
            if !showsSidebar {
                #expect(abs(frame.minX) <= 1 && abs(frame.maxX - window.frame.width) <= 1,
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

        // Compare at one fixed window size; native columns may resize with the window.
        mailbox.selectedMailbox = .combined(SystemLabel.inbox)
        try await settleMail(in: controller.view, window: window)
        #expect(try mailSplit(in: controller.view) === mail)
        for (pane, width) in zip(mailPanes, mailWidths) {
            #expect(abs(pane.frame.width - width) <= 1, "Returning from Attachments must restore Mail's pane widths")
        }

        split = try await openAttachments()
        for width in [1_280, 960, 720, 1_280] {
            window.setContentSize(NSSize(width: width, height: 760))
            let compact = CGFloat(width) < Tokens.Layout.sidebarCompactWidth
            try await expectBoundary(split, showsSidebar: !compact)
            if compact {
                let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
                try await pressToolbarButton(in: window, identifier: "workspace.sidebar")
                var popover: NSWindow?
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                repeat {
                    try await settle()
                    popover = NSApp.windows.first {
                        $0.isVisible && !visibleWindows.contains(ObjectIdentifier($0))
                            && $0.contentView.map { !tables(in: $0).isEmpty } == true
                    }
                } while popover == nil && ContinuousClock.now < deadline
                let sidebarPopover = try #require(popover, "The compact Attachments sidebar button must open its sidebar")
                let table = try #require(sidebarPopover.contentView.flatMap { tables(in: $0).first })
                #expect(table.numberOfRows > 0, "Mailbox navigation must remain available in the compact sidebar")
                try await pressToolbarButton(in: window, identifier: "workspace.sidebar")
                let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                repeat { try await settle() } while sidebarPopover.isVisible && ContinuousClock.now < closeDeadline
                #expect(!sidebarPopover.isVisible)
            }
        }
        #expect(abs(try #require(split.arrangedSubviews.first).frame.width - Tokens.Layout.sidebarMaxWidth) <= 1,
            "Widening the window must restore the Attachments sidebar's dragged width")
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
        // This checks toolbar safe area without an intentional quick-filter header.
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
            try await expectMailVisible(in: controller.view, window: window, searchFolds: searchFolds)
        }
        try await expectSidebarGutterDrags(in: controller.view, window: window)
        // Below the three column minimums the sidebar steps aside, and it comes back with the room.
        window.setContentSize(NSSize(width: Tokens.Layout.windowMinWidth, height: 760))
        try await expectColumnsFit(in: controller.view, window: window, sidebarCollapsed: true)
        try expectLeadingEdgeVisible(in: controller.view, label: "\(Int(Tokens.Layout.windowMinWidth)) points")
        window.setContentSize(NSSize(width: 1_280, height: 760))
        try await expectColumnsFit(in: controller.view, window: window, sidebarCollapsed: false)
        try await settleMail(in: controller.view, window: window)
        try await expectMailVisible(in: controller.view, window: window, searchFolds: false)
        // Opening the assistant widens a window too narrow for the list and reader
        // beside it, and the window keeps that width while the assistant shows.
        window.setContentSize(NSSize(width: Tokens.Layout.windowMinWidth, height: 760))
        try await settle()
        try await toggleAssistant(in: window, rootView: controller.view, opens: true)
        try await settle()
        try await expectColumnsBesideAssistant(in: controller.view, window: window, label: "opening at 720 points")
        for width in [CGFloat(960), Tokens.Layout.windowMinWidth] {
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
        try await expectMailVisible(in: controller.view, window: window, searchFolds: false)
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

    private func expectMailVisible(in rootView: NSView, window: NSWindow, searchFolds: Bool) async throws {
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
        for table in mailTables {
            try #require(table.numberOfRows > 0)
            let row = table.convert(table.rect(ofRow: 0), to: nil)
            #expect(row.maxY <= window.contentLayoutRect.maxY + 1, "First row is covered by the toolbar at width \(width)")
            #expect(row.maxY >= window.contentLayoutRect.maxY - Tokens.Space.s4, "The toolbar inset must not be counted twice")
            #expect(row.minY >= window.contentLayoutRect.minY - 1)
            #expect(row.minX >= -1 && row.maxX <= window.frame.width + 1)
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
        // A closed assistant leaves the split at least as wide as the window.
        func isOpen() throws -> Bool { try mailSplit(in: rootView).frame.width < window.frame.width - Tokens.Border.hairline }
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

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    /// AppKit mirrors item changes across toolbars that share an identifier,
    /// and the test host's own mail window already uses the workspace one.
    private func workspaceToolbarIdentifier() -> String {
        "\(MailWindowPreferences.toolbarID).\(UUID().uuidString)"
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
        func expectSharedPositions() async throws {
            try await settle()
            #expect(window.toolbar?.identifier == toolbarIdentifier, "Hosted toolbar state must stay separate from other windows")
            let width = Int(window.frame.width)
            let identifiers = ["workspace.sidebar", "workspace.destination", "mail.compose", "workspace.search", "workspace.tasks", "workspace.assistant"]
            var frames: [String: NSRect] = [:]
            for identifier in identifiers {
                let item = try #require(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == identifier },
                    "Shared control \(identifier) must remain visible at \(width) points")
                let view = try #require(item.view)
                let frame = view.convert(view.bounds, to: nil)
                frames[identifier] = frame
                let followsSidebar = ["workspace.sidebar", "workspace.destination", "mail.compose"].contains(identifier)
                if let baseline = sharedFrames[width], let expected = baseline[identifier] {
                    let origin = followsSidebar ? try #require(frames["workspace.sidebar"]).minX : 0
                    let expectedOrigin = followsSidebar ? try #require(baseline["workspace.sidebar"]).minX : 0
                    #expect(abs((frame.minX - origin) - (expected.minX - expectedOrigin)) <= 1
                        && abs((frame.maxX - origin) - (expected.maxX - expectedOrigin)) <= 1,
                        "\(identifier) moved from \(expected) to \(frame) when switching views at \(width) points")
                }
            }
            let split = try mailSplit(in: controller.view)
            let sidebar = try #require(split.arrangedSubviews.first)
            let sidebarEdge = split.isSubviewCollapsed(sidebar) ? 0 : sidebar.convert(sidebar.bounds, to: nil).maxX
            #expect(try #require(frames["workspace.sidebar"]).minX >= sidebarEdge - 1,
                "The leading toolbar controls must clear the current native sidebar")
            if sharedFrames[width] == nil { sharedFrames[width] = frames }
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
        try await expectToolbar(in: window, width: 1_280, section: "calendar.", spacesAfter: ["calendar.mode"])
        try await expectSharedPositions()
        try await expectToolbar(in: window, width: 960, section: "calendar.", spacesAfter: ["calendar.mode"])
        try await expectSharedPositions()
        try await expectToolbar(in: window, width: Tokens.Layout.windowMinWidth,
            section: "calendar.", spacesAfter: ["calendar.mode"])
        try await expectSharedPositions()
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
