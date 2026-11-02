import AppKit
import Darwin
import MailStore
import SwiftUI
import Testing
@testable import Tern

/// Inspect native attachment in a background window. These are functional
/// checks; background layout in an occluded window cannot measure visible latency.
@Suite(.serialized) @MainActor struct WorkspaceRetentionTests {
    @Test
    func switchingModesPreservesNativeMailState() async throws {
        let configuration = "normal"
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"),
            "Workspace tests require isolated synthetic accounts")
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        app.destination = .mail
        let loaded = ContinuousClock.now.advanced(by: .seconds(5))
        while !mailbox.hasSyncedOnce, ContinuousClock.now < loaded {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(mailbox.hasSyncedOnce)

        let suite = "WorkspaceRetentionTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let toolbarIdentifier = "\(MailWindowPreferences.toolbarID).\(UUID().uuidString)"
        let controller = NSHostingController(rootView:
            WorkspaceView(mailbox: mailbox)
                .environment(app).environment(\.workspaceToolbarID, toolbarIdentifier).defaultAppStorage(settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1_280, height: 760))
        window.autorecalculatesKeyViewLoop = true
        window.orderBack(nil)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }

        var mailTables: [NSTableView] = []
        let nativeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            try await settle(controller.view, in: window)
            mailTables = tablesInMailColumns(of: controller.view)
        } while (mailTables.count < 2 || mailTables.contains { $0.numberOfRows == 0 })
            && ContinuousClock.now < nativeDeadline
        try #require(mailTables.count >= 2, "The background window must materialize the native Mail lists")
        try #require(mailTables.allSatisfy { $0.window === window && $0.numberOfRows > 0 })
        let scrolls = try mailTables.map { try #require($0.enclosingScrollView) }
        for scroll in scrolls {
            let clip = scroll.contentView
            let documentHeight = scroll.documentView?.bounds.height ?? 0
            let y = min(120, max(0, documentHeight - clip.bounds.height))
            // Short lists begin at a negative origin when the toolbar reserves
            // a top inset. Keep the initial position within AppKit's scroll bounds.
            var bounds = clip.bounds
            bounds.origin.y = y
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }
        try await settle(controller.view, in: window)
        let offsets = scrolls.map { $0.contentView.bounds.origin }
        let tableCounters = mailTables.map { table in
            let counter = NativeWindowMoveCounter(frame: .zero)
            table.addSubview(counter)
            return counter
        }
        let probes = descendants(of: controller.view).compactMap { $0 as? MailColumnProbe.ProbeView }
        let toolbarInset = try #require(probes.first?.toolbarInset)
        let visibleProbes = descendants(of: controller.view).compactMap { $0 as? VisibleContentProbe.ProbeView }
        let mailboxProbes = visibleProbes.filter { $0.kinds.contains(.mailbox) }
        func chromeReady(_ destination: WorkspaceDestination) -> Bool {
            toolbarShows(destination, in: window)
                && searchShows(destination, in: window)
        }
        try #require(!mailboxProbes.isEmpty && mailboxProbes.allSatisfy { $0.isActive },
            "The native Mail probes must reflect the initial active destination")
        try await waitFor(controller.view, in: window, expecting: "Initial visible Mail toolbar") {
            chromeReady(.mail)
        }
        try #require(window.toolbar?.identifier == toolbarIdentifier,
            "Hosted toolbar state must stay separate from other windows")
        try #require(mailSplit(in: controller.view) != nil)
        let initialToolbar = toolbarViews(in: window)
        let initialLayout = nativeLayout(in: window, root: controller.view, tables: mailTables, destination: .mail)
        let mailVisibility = toolbarVisibility(in: window)
        print("WORKSPACE_TOOLBAR_STATE: config=\(configuration), destination=mail, items=\(toolbarMetadata(in: window))")
        try #require(toolbarShows(.mail, in: window),
            "The background window must materialize visible Mail controls without Calendar controls")
        let mailCounts = { probes.map { NativeMoves($0.windowAttachmentCount, $0.windowDetachmentCount, $0.superviewMoveCount) } }
        let visibleCounts = { visibleProbes.map { NativeMoves($0.windowAttachmentCount, $0.windowDetachmentCount, $0.superviewMoveCount) } }
        let tableCounts = { tableCounters.map { NativeMoves($0.attachments, $0.detachments, 0) } }
        let initialMailCounts = mailCounts()
        let initialVisibleCounts = visibleCounts()
        let initialTableCounts = tableCounts()

        app.destination = .calendar
        try await waitFor(controller.view, in: window, expecting: "Initial switch to Calendar") {
            mailboxProbes.allSatisfy { !$0.isActive } && chromeReady(.calendar)
        }
        try #require(mailboxProbes.allSatisfy { !$0.isActive },
            "The background native graph must apply the switch to Calendar")
        try #require(chromeReady(.calendar), "The toolbar and search must match the active destination")
        let calendarLayout = nativeLayout(in: window, root: controller.view, tables: mailTables, destination: .calendar)
        let calendarVisibility = toolbarVisibility(in: window)
        print("WORKSPACE_TOOLBAR_STATE: config=\(configuration), destination=calendar, items=\(toolbarMetadata(in: window))")
        let attachedWhileInactive = mailTables.filter { $0.window === window }.count
        let inactiveOffsets = scrolls.map { $0.contentView.bounds.origin }
        print("WORKSPACE_RETENTION: config=\(configuration), attached while inactive=\(attachedWhileInactive)/\(mailTables.count), offsets preserved=\(offsetsMatch(offsets, inactiveOffsets))")
        #expect(attachedWhileInactive == mailTables.count)
        // Calendar temporarily changes the toolbar host's sidebar width, which
        // changes the hidden list's horizontal origin. Its scroll position
        // must stay fixed vertically; both axes are checked on return below.
        #expect(zip(offsets, inactiveOffsets).allSatisfy { abs($0.y - $1.y) < 0.5 })

        app.destination = .mail
        try await waitFor(controller.view, in: window, expecting: "Initial return to Mail") {
            mailboxProbes.allSatisfy { $0.isActive } && chromeReady(.mail)
        }
        try #require(mailboxProbes.allSatisfy { $0.isActive },
            "The background native graph must apply the return to Mail")
        try #require(toolbarShows(.mail, in: window),
            "The background toolbar must restore Mail controls and hide Calendar controls")
        let returnedTables = tablesInMailColumns(of: controller.view)
        for (index, table) in mailTables.enumerated() {
            #expect(returnedTables.contains { $0 === table }, "Returning to Mail must reuse its native table")
            #expect(table.window === window)
            #expect(table.enclosingScrollView === scrolls[index])
        }
        #expect(offsetsMatch(offsets, scrolls.map { $0.contentView.bounds.origin }),
            "Returning to Mail must preserve list scroll offsets")
        print("WORKSPACE_NATIVE_MOVES: config=\(configuration), Mail probes=\(changes(mailCounts(), since: initialMailCounts)), content probes=\(changes(visibleCounts(), since: initialVisibleCounts)), native tables=\(changes(tableCounts(), since: initialTableCounts))")
        let returnedToolbar = toolbarViews(in: window)
        let replacedToolbarViews = initialToolbar.keys.filter { key in
            returnedToolbar[key] != nil && initialToolbar[key] !== returnedToolbar[key]
        }.sorted()
        print("WORKSPACE_TOOLBAR_REPLACED: config=\(configuration), items=\(replacedToolbarViews)")
        expectSameLayout(nativeLayout(in: window, root: controller.view, tables: mailTables, destination: .mail),
            as: initialLayout)

        // Thread CPU includes work performed between these awaits, but excludes
        // the settling sleeps. This compares background layout work only.
        var mailCPU: [Double] = []
        var calendarCPU: [Double] = []
        var mailTailCPU: [Double] = []
        var calendarTailCPU: [Double] = []
        print("WORKSPACE_CORPUS: config=\(configuration), accounts=\(mailbox.accounts.count), mailRows=\(mailbox.listItems.count), nativeTableRows=\(mailTables.map(\.numberOfRows)), calendarEvents=\(app.calendar.events.count)")
        print("WORKSPACE_LAYOUT_POLICY: natural invalidation; no explicit needsLayout")
        print("WORKSPACE_WARM_SAMPLE_READY: pid=\(ProcessInfo.processInfo.processIdentifier), config=\(configuration)")
        fflush(nil)
        try await Task.sleep(for: .seconds(2))
        print("WORKSPACE_WARM_SAMPLE_BEGIN: pid=\(ProcessInfo.processInfo.processIdentifier), config=\(configuration)")
        fflush(nil)
        for _ in 0..<12 {
            for destination in [WorkspaceDestination.calendar, .mail] {
                let previousPublications = toolbarInset.diagnosticPublicationCount
                let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                app.destination = destination
                try await waitFor(controller.view, in: window, expecting: "Warm switch to \(destination.rawValue)") {
                    let mailIsActive = destination == .mail
                    return mailboxProbes.allSatisfy { $0.isActive == mailIsActive }
                        && chromeReady(destination)
                }
                let milliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1_000_000
                if destination == .mail { mailCPU.append(milliseconds) } else { calendarCPU.append(milliseconds) }
                // Read-only geometry checks run outside the measured interval.
                expectSameLayout(nativeLayout(in: window, root: controller.view, tables: mailTables, destination: destination),
                    as: destination == .mail ? initialLayout : calendarLayout)
                let expectedVisibility = destination == .mail ? mailVisibility : calendarVisibility
                #expect(toolbarVisibility(in: window) == expectedVisibility)
                let tailStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                try await settle(controller.view, in: window)
                let tail = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - tailStarted) / 1_000_000
                if destination == .mail { mailTailCPU.append(tail) } else { calendarTailCPU.append(tail) }
                #expect(chromeReady(destination))
                #expect(toolbarVisibility(in: window) == expectedVisibility,
                    "Visibility must remain settled through the following layout turns")
                let publications = toolbarInset.diagnosticPublications.filter { $0.sequence > previousPublications }
                    .map { "\($0.top)@\($0.source)" }
                print("WORKSPACE_INSET: config=\(configuration), destination=\(destination.rawValue), publications=\(toolbarInset.diagnosticPublicationCount - previousPublications), values=\(publications)")
            }
        }
        print("WORKSPACE_WARM_SAMPLE_END: pid=\(ProcessInfo.processInfo.processIdentifier), config=\(configuration)")
        fflush(nil)
        print("WORKSPACE_BACKGROUND_CPU_MS: config=\(configuration), automatic key loop=\(window.autorecalculatesKeyViewLoop), Mail=\(mailCPU.map { String(format: "%.1f", $0) }), Calendar=\(calendarCPU.map { String(format: "%.1f", $0) })")
        print("WORKSPACE_BACKGROUND_TAIL_CPU_MS: config=\(configuration), Mail=\(mailTailCPU.map { String(format: "%.1f", $0) }), Calendar=\(calendarTailCPU.map { String(format: "%.1f", $0) })")
        try await verifyObservableUpdates(mailbox: mailbox, settings: settings,
            root: controller.view, window: window)
        await app.signOut()
    }

    private func settle(_ view: NSView, in window: NSWindow) async throws {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func offsetsMatch(_ lhs: [NSPoint], _ rhs: [NSPoint]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0.x - $1.x) < 1 && abs($0.y - $1.y) < 1 }
    }

    private func tablesInMailColumns(of view: NSView) -> [NSTableView] {
        descendants(of: view).compactMap { $0 as? MailColumnProbe.ProbeView }.flatMap { probe -> [NSTableView] in
            var column: NSView = probe
            while let parent = column.superview {
                if let split = parent as? NSSplitView, split.isVertical {
                    return split.isSubviewCollapsed(column) ? []
                        : descendants(of: column).compactMap { $0 as? NSTableView }
                }
                column = parent
            }
            return []
        }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func toolbarViews(in window: NSWindow) -> [String: NSView] {
        (window.toolbar?.items ?? []).reduce(into: [:]) { result, item in
            if let view = item.view { result[item.itemIdentifier.rawValue] = view }
        }
    }

    private func toolbarMetadata(in window: NSWindow) -> [String] {
        toolbarVisibility(in: window).map { "\($0.path):hidden=\($0.hidden),visible=\($0.visible),view=\($0.viewVisible)" }
    }

    private struct ToolbarVisibility: Equatable {
        let path: String
        let identity: ObjectIdentifier
        let hidden: Bool
        let visible: Bool
        let viewVisible: Bool
    }

    private func toolbarVisibility(in window: NSWindow) -> [ToolbarVisibility] {
        func capture(_ item: NSToolbarItem, path: String) -> [ToolbarVisibility] {
            let viewVisible = item.isVisible && (item.view.map { $0.window === window && !$0.isHiddenOrHasHiddenAncestor
                && !$0.visibleRect.isEmpty && $0.alphaValue > 0.01 } ?? false)
            var result = [ToolbarVisibility(path: path, identity: ObjectIdentifier(item),
                hidden: item.isHidden, visible: item.isVisible, viewVisible: viewVisible)]
            if let group = item as? NSToolbarItemGroup {
                #expect(!group.subitems.contains { $0 is NSToolbarItemGroup }, "AppKit does not support nested toolbar groups")
                for (index, child) in group.subitems.enumerated() {
                    result += capture(child, path: "\(path)/\(index):\(child.itemIdentifier.rawValue)")
                }
            }
            return result
        }
        return (window.toolbar?.items ?? []).enumerated().flatMap { index, item in
            capture(item, path: "\(index):\(item.itemIdentifier.rawValue)")
        }
    }

    private func searchShows(_ destination: WorkspaceDestination, in window: NSWindow) -> Bool {
        let fields = visibleToolbarItems(in: window).filter { $0.itemIdentifier.rawValue == "workspace.search" }
            .compactMap(\.view).flatMap { descendants(of: $0) }.compactMap { $0 as? NSSearchField }
            .filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        let placeholder = destination == .mail ? "Search mail" : "Search events"
        return fields.count == 1 && fields.first?.placeholderString == placeholder
    }

    private func visibleToolbarItems(in window: NSWindow) -> [NSToolbarItem] {
        (window.toolbar?.visibleItems ?? []).filter { item in
            guard let view = item.view, view.window === window,
                  !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return false }
            var current: NSView? = view
            while let ancestor = current {
                guard ancestor.alphaValue > 0.01 else { return false }
                current = ancestor.superview
            }
            let frame = view.convert(view.bounds, to: nil)
            return frame.intersects(NSRect(origin: .zero, size: window.frame.size))
        }
    }

    private func toolbarShows(_ destination: WorkspaceDestination, in window: NSWindow) -> Bool {
        let visibleIDs = visibleToolbarItems(in: window).map { $0.itemIdentifier.rawValue }
        guard visibleIDs.contains("workspace.search"),
              !visibleIDs.contains(where: { $0.hasPrefix("calendar.") }) else { return false }
        if destination == .mail {
            return visibleIDs.contains("mail.compose") && visibleIDs.contains("mail.archive")
        }
        guard !visibleIDs.contains("mail.compose"), !visibleIDs.contains("mail.archive"),
              let root = window.contentView else { return false }
        let controls = WorkspaceAuditAccessibility.elements(in: root).filter { $0.isVisible(in: window) }
        let buttonsReady = ["calendar.today", "calendar.goToDate", "calendar.newEvent"].allSatisfy { identifier in
            controls.contains { $0.identifier == identifier && $0.supportsPress && $0.hasHitTarget(in: window) }
        }
        return buttonsReady && controls.contains {
            $0.identifier == "calendar.viewMode" && $0.hasHitTarget(in: window)
        }
    }

    private struct NativeLayout {
        let destination: WorkspaceDestination
        let itemIDs: [String]
        let itemIdentities: [ObjectIdentifier]
        let itemViewIdentities: [ObjectIdentifier?]
        let visibleItemIDs: [String]
        let visibleControlIDs: [String]
        let geometry: [String: [CGFloat]]
    }

    private func nativeLayout(in window: NSWindow, root: NSView, tables: [NSTableView],
                              destination: WorkspaceDestination) -> NativeLayout {
        func rect(_ value: NSRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
        func insets(_ value: NSEdgeInsets) -> [CGFloat] { [value.top, value.left, value.bottom, value.right] }
        func frame(_ view: NSView) -> [CGFloat] { rect(view.convert(view.bounds, to: nil)) }
        let items = window.toolbar?.items ?? []
        let controls = visibleToolbarItems(in: window)
        var geometry = ["contentLayout": rect(window.contentLayoutRect), "root": frame(root),
                        "root.safeArea": insets(root.safeAreaInsets)]
        for (index, item) in controls.enumerated() {
            if let view = item.view { geometry["toolbar.\(index).\(item.itemIdentifier.rawValue)"] = frame(view) }
        }
        if let split = mailSplit(in: root) {
            geometry["split"] = frame(split)
            for (index, column) in split.arrangedSubviews.enumerated() {
                geometry["column.\(index)"] = frame(column)
                geometry["column.\(index).safeArea"] = insets(column.safeAreaInsets)
            }
        }
        for (index, table) in tables.enumerated() {
            guard let scroll = table.enclosingScrollView else { continue }
            let prefix = "table.\(index)"
            geometry[prefix] = frame(table)
            geometry["\(prefix).scroll"] = frame(scroll)
            geometry["\(prefix).scroll.safeArea"] = insets(scroll.safeAreaInsets)
            geometry["\(prefix).scroll.insets"] = insets(scroll.contentInsets)
            geometry["\(prefix).clip"] = frame(scroll.contentView)
            geometry["\(prefix).clip.safeArea"] = insets(scroll.contentView.safeAreaInsets)
            geometry["\(prefix).clip.insets"] = insets(scroll.contentView.contentInsets)
            if table.numberOfRows > 0 {
                let row = table.convert(table.rect(ofRow: 0), to: nil)
                let viewport = scroll.convert(scroll.bounds, to: nil)
                geometry["\(prefix).firstRow"] = rect(row)
                geometry["\(prefix).rowInset"] = [row.minX - viewport.minX, viewport.maxY - row.maxY]
            }
        }
        return NativeLayout(destination: destination, itemIDs: items.map { $0.itemIdentifier.rawValue },
            itemIdentities: items.map(ObjectIdentifier.init),
            itemViewIdentities: items.map { $0.view.map(ObjectIdentifier.init) },
            visibleItemIDs: (window.toolbar?.visibleItems ?? []).map { $0.itemIdentifier.rawValue },
            visibleControlIDs: controls.map { $0.itemIdentifier.rawValue }, geometry: geometry)
    }

    private func expectSameLayout(_ current: NativeLayout, as baseline: NativeLayout) {
        #expect(current.destination == baseline.destination)
        #expect(current.itemIDs == baseline.itemIDs, "Native toolbar item order")
        #expect(current.visibleItemIDs == baseline.visibleItemIDs, "Visible native toolbar item order")
        #expect(current.visibleControlIDs == baseline.visibleControlIDs, "Attached visible toolbar controls")
        #expect(current.itemIdentities == baseline.itemIdentities, "Native toolbar items must survive mode switches")
        #expect(current.itemViewIdentities == baseline.itemViewIdentities, "Native toolbar views must survive mode switches")
        #expect(current.geometry.keys.sorted() == baseline.geometry.keys.sorted())
        for (key, values) in current.geometry {
            guard let previous = baseline.geometry[key] else { continue }
            let matches = values.count == previous.count && zip(values, previous).allSatisfy { abs($0 - $1) < 1 }
            #expect(matches, "\(current.destination.rawValue) layout changed at \(key): \(previous) → \(values)")
        }
    }

    /// These changes leave MailColumnsContent's explicit identity unchanged.
    /// Its descendants must still receive their own model observations.
    private func verifyObservableUpdates(mailbox: MailboxModel, settings: UserDefaults,
                                         root: NSView, window: NSWindow) async throws {
        let inbox = mailbox.selectedMailbox
        let originalList = try #require(table(in: root, pane: .list))
        mailbox.selectedMailbox = .combined(MailboxModel.outboxID)
        try await waitFor(root, in: window, expecting: "Outbox replaces the mail list") {
            guard let current = table(in: root, pane: .list) else { return false }
            return current !== originalList && current.numberOfRows == mailbox.selectedOutbox.count
        }
        let outboxList = try #require(table(in: root, pane: .list))
        mailbox.selectedMailbox = inbox
        try await waitFor(root, in: window, expecting: "Inbox replaces the Outbox list") {
            guard let current = table(in: root, pane: .list) else { return false }
            return current !== outboxList && current.numberOfRows > 0
        }
        mailbox.search.update("workspace-no-match-\(UUID().uuidString)")
        try await waitFor(root, in: window, expecting: "Search publishes empty results") {
            mailbox.search.isActive && mailbox.listItems.isEmpty && table(in: root, pane: .list)?.numberOfRows == 0
        }
        mailbox.search.clear()
        try await waitFor(root, in: window, expecting: "Clearing search restores mail rows") {
            !mailbox.search.isActive && !mailbox.listItems.isEmpty && (table(in: root, pane: .list)?.numberOfRows ?? 0) > 0
        }
        settings.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        let selected = try #require(mailbox.listItems.first?.id.threadKey)
        mailbox.selectedThreadIDs = [selected]
        try await waitFor(root, in: window, expecting: "Selection presents a reader") {
            descendants(of: root).contains { ($0 as? VisibleContentProbe.ProbeView)?.kind == .readerHeader }
        }
        mailbox.selectedThreadIDs = []
        try await waitFor(root, in: window, expecting: "Clearing selection removes the reader") {
            !descendants(of: root).contains { ($0 as? VisibleContentProbe.ProbeView)?.kind == .readerHeader }
        }
        settings.set(true, forKey: MailWindowPreferences.hidesReaderKey)
        try await waitFor(root, in: window, expecting: "Hiding the reader creates two columns") { mailSplit(in: root)?.arrangedSubviews.count == 2 }
        settings.set(false, forKey: MailWindowPreferences.hidesReaderKey)
        try await waitFor(root, in: window, expecting: "Restoring the reader creates three columns") { mailSplit(in: root)?.arrangedSubviews.count == 3 }
    }

    private func waitFor(_ root: NSView, in window: NSWindow, expecting change: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !condition(), ContinuousClock.now < deadline { try await settle(root, in: window) }
        try #require(condition(), "Background native content: \(change)")
    }

    private func table(in root: NSView, pane: AssistantMailPaneSizing.Pane) -> NSTableView? {
        guard let probe = descendants(of: root).compactMap({ $0 as? MailColumnProbe.ProbeView }).first(where: { $0.pane == pane }) else { return nil }
        var column: NSView = probe
        while let parent = column.superview {
            if let split = parent as? NSSplitView, split.isVertical {
                return descendants(of: column).compactMap { $0 as? NSTableView }.first
            }
            column = parent
        }
        return nil
    }

    private func mailSplit(in root: NSView) -> NSSplitView? {
        descendants(of: root).compactMap { $0 as? MailColumnProbe.ProbeView }
            .first { $0.pane == .navigation }.flatMap { EnclosingSplitDivider(of: $0)?.split }
    }

    private func changes(_ values: [NativeMoves], since previous: [NativeMoves]) -> String {
        zip(values, previous).map { current, prior in
            "attach \(current.attachments - prior.attachments)/detach \(current.detachments - prior.detachments)/superview \(current.superview - prior.superview)"
        }.joined(separator: ", ")
    }

    private struct NativeMoves {
        let attachments: Int
        let detachments: Int
        let superview: Int
        init(_ attachments: Int, _ detachments: Int, _ superview: Int) {
            self.attachments = attachments; self.detachments = detachments; self.superview = superview
        }
    }

    private final class NativeWindowMoveCounter: NSView {
        private(set) var attachments = 0
        private(set) var detachments = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detachments += 1 } else { attachments += 1 }
        }
    }
}
