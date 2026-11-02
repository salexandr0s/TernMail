import AppKit
import GmailAPI
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct WorkspaceDesignVisualAudit {
    @Test func toolbarNavigationAndResizePreserveMail() async throws {
        let host = try await WorkspaceDesignHost(width: 1_280, height: 760, scheme: .light,
            restoredMailbox: .combined(AttachmentLibraryModel.mailboxID))
        defer { host.close() }
        // Restoration happens before the first host layout. A selected segment
        // alone must never leave the retained Mail panes exposed underneath.
        for width in [CGFloat(1_280), 720, 1_280] {
            host.window.setContentSize(NSSize(width: width, height: 760))
            try await host.expectSectionVisible(.attachments)
            _ = try host.expectDestinationControl()
            #expect(abs(host.window.contentLayoutRect.width - width) <= 1)
        }
        try await host.select(.mail)
        host.window.setContentSize(NSSize(width: 1_079, height: 480))
        try await host.expectSectionVisible(.mail)
        let list = try #require(host.mailTable(pane: .list))
        let scroll = try #require(list.enclosingScrollView)
        let selected = try #require(host.mailbox.listItems.first?.id.threadKey)
        host.mailbox.selectedThreadIDs = [selected]
        try await host.waitUntil("Native mail selection") { list.selectedRow >= 0 }
        let selectedRow = list.selectedRow
        let initialOffset = scroll.contentView.bounds.origin
        let destination = try #require(host.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "workspace.destination" })

        for width in [CGFloat(720), 960, 1_080, 1_081, 1_280, 1_079] {
            host.window.setContentSize(NSSize(width: width, height: 480))
            try await host.expectSectionVisible(.mail)
            _ = try host.expectDestinationControl()
            #expect(abs(host.window.contentLayoutRect.width - width) <= 1,
                "Resizing must not enlarge the requested window")
            #expect(host.mailTable(pane: .list) === list, "Resizing must retain the native message list")
            #expect(list.enclosingScrollView === scroll, "Resizing must retain its scroll view")
            #expect(list.window === host.window)
            #expect(list.selectedRow == selectedRow)
            #expect(host.mailbox.selectedThreadIDs == [selected])
            #expect(host.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "workspace.destination" } === destination,
                "The destination control must keep its native toolbar identity")
        }
        #expect(abs(scroll.contentView.bounds.origin.y - initialOffset.y) <= 1,
            "Returning to the original size must preserve the message list's scroll position")

        for width in [CGFloat(1_280), 720] {
            host.window.setContentSize(NSSize(width: width, height: 760))
            host.mailbox.selectedThreadIDs = [selected]
            try await host.select(.calendar)
            try await host.select(.mail)
            #expect(host.mailbox.selectedThreadIDs == [selected], "Calendar must retain the selected mail conversation")
            try await host.select(.attachments)
            try await host.select(.mail)
            #expect(host.mailbox.selectedLabelID == SystemLabel.inbox)
            #expect(host.mailTable(pane: .list) === list)
            #expect(list.enclosingScrollView === scroll && list.window === host.window)
        }
        await host.app.signOut()
    }

    @Test func compactAttachmentNavigationPreservesQueryAndSelection() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"),
            "Attachment navigation checks require synthetic accounts")
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let model = AttachmentLibraryModel(mailbox: mailbox)
        let toolbar = AttachmentLibraryToolbarState()
        // This component host has no workspace window-width coordinator.
        toolbar.updateCompact(true)
        toolbar.attachSidebarModel(model)
        let controller = NSHostingController(rootView: VStack(spacing: 0) {
            Button("Library navigation", action: toolbar.toggleSidebar)
                .accessibilityIdentifier("attachments.audit.navigation")
                .popover(isPresented: Bindable(toolbar).isPopoverPresented) {
                    AttachmentLibrarySidebarPopover(toolbar: toolbar)
                }
            AttachmentLibraryDestination(model: model, toolbar: toolbar)
        }.environment(app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 720, height: 760))
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil; toolbar.detachSidebarModel(model) }

        func waitFor(_ description: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            repeat {
                window.layoutIfNeeded()
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            } while !condition() && ContinuousClock.now < deadline
            try #require(condition(),
                "\(description): compact=\(toolbar.isCompact), ready=\(model.isPageReady), loading=\(model.isLoading), files=\(model.items.count), width=\(window.frame.width)")
        }
        func press(_ identifier: String, in target: NSWindow) throws {
            let control = try #require(WorkspaceAuditAccessibility.matching(identifier, in: target)
                .first { $0.supportsPress && $0.hasHitTarget(in: target) }, "Missing clickable \(identifier)")
            try #require(control.press(), "\(identifier) must activate")
        }
        func openNavigation() async throws -> NSWindow {
            let existing = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            try press("attachments.audit.navigation", in: window)
            var popup: NSWindow?
            try await waitFor("Compact attachment navigation") {
                popup = NSApp.windows.first {
                    $0.isVisible && !existing.contains(ObjectIdentifier($0))
                        && !WorkspaceAuditAccessibility.matching("attachments.sidebar.allAccounts", in: $0).isEmpty
                }
                return popup != nil
            }
            return try #require(popup)
        }
        func choose(_ identifier: String, in popup: NSWindow) async throws {
            try press(identifier, in: popup)
            try await waitFor("The selected attachment scope must close navigation and load its page") {
                !popup.isVisible && !toolbar.isPopoverPresented && model.isPageReady && !model.isLoading
            }
        }

        try await waitFor("Synthetic mail baseline") {
            mailbox.accounts.count == 2 && mailbox.accounts.allSatisfy(\.hasSyncedOnce)
        }
        try await prepareWorkspaceAuditAttachments(mailbox)
        try await waitFor("Attachment page and compact navigation") {
            toolbar.isCompact && model.isPageReady && !model.isLoading && !model.items.isEmpty
        }
        #expect(abs(window.frame.width - 720) <= 1, "The compact component host must remain at its requested width")
        try #require(model.availableAccounts.count > 1, "The account filter check requires both synthetic accounts")
        let item = try #require(model.items.first)
        if ProcessInfo.processInfo.environment["TERN_WORKSPACE_DESIGN_AUDIT_DIR"] != nil {
            let savedMode = toolbar.viewMode
            defer { toolbar.viewMode = savedMode; model.selection.removeAll() }
            model.selection = [item.id]
            toolbar.viewMode = .list
            try await WorkspaceSupplementCapture.record(window, name: "attachments-populated-selected-list")
            toolbar.viewMode = .grid
            try await WorkspaceSupplementCapture.record(window, name: "attachments-populated-selected-grid")
            let existing = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            let filters = try #require(WorkspaceAuditAccessibility.elements(in: controller.view)
                .first { $0.label == "Filters" && $0.supportsPress && $0.hasHitTarget(in: window) })
            try #require(filters.press())
            var filterWindow: NSWindow?
            try await waitFor("Attachment filters popover") {
                filterWindow = NSApp.windows.first { candidate in
                    guard candidate.isVisible, !existing.contains(ObjectIdentifier(candidate)),
                          let content = candidate.contentView else { return false }
                    return WorkspaceAuditAccessibility.elements(in: content).contains { $0.identifier == "attachments.filters" }
                }
                return filterWindow != nil
            }
            let popup = try #require(filterWindow)
            try await WorkspaceSupplementCapture.record(popup, name: "attachments-populated-filters")
            let popupContent = try #require(popup.contentView)
            let popupElements = WorkspaceAuditAccessibility.elements(in: popupContent)
            let doneCandidate = popupElements.first {
                $0.label == "Done" && $0.supportsPress && $0.hasHitTarget(in: popup)
            }
            let done = try #require(doneCandidate)
            try #require(done.press())
            try await waitFor("Attachment filter dismissal") { !popup.isVisible }
        }
        model.search = item.filename
        try await waitFor("Attachment search results") {
            model.isPageReady && !model.isLoading && model.items.contains { $0.id == item.id }
                && toolbar.searchText == item.filename
        }
        model.selection = [item.id]
        let query = model.query
        var popup = try await openNavigation()
        #expect(model.query == query && model.selection == [item.id],
            "Opening navigation must preserve the file query and selection")
        try press("attachments.audit.navigation", in: window)
        try await waitFor("Navigation dismissal") { !popup.isVisible }
        popup = try await openNavigation()
        #expect(model.query == query && model.selection == [item.id],
            "Reopening navigation must preserve the file query and selection")

        let accountID = "attachments.sidebar.account.\(item.accountID)"
        try await choose(accountID, in: popup)
        #expect(model.query.accountIDs == [item.accountID])
        #expect(model.search == item.filename && toolbar.searchText == item.filename)
        #expect(model.selection.isEmpty, "Changing the account must clear the previous result selection")
        popup = try await openNavigation()
        #expect(WorkspaceAuditAccessibility.matching(accountID, in: popup).contains { $0.isSelected })
        let categoryID = "attachments.sidebar.category.\(AttachmentCategory.uncategorized.rawValue)"
        try await choose(categoryID, in: popup)
        #expect(model.category == .uncategorized && model.query.accountIDs == [item.accountID])
        #expect(model.search == item.filename && toolbar.searchText == item.filename)
        popup = try await openNavigation()
        #expect(WorkspaceAuditAccessibility.matching(categoryID, in: popup).contains { $0.isSelected })
        #expect(WorkspaceAuditAccessibility.matching(accountID, in: popup).contains { $0.isSelected })
        try await choose("attachments.sidebar.allCategories", in: popup)
        #expect(model.category == nil && model.query.accountIDs == [item.accountID])
        popup = try await openNavigation()
        try await choose("attachments.sidebar.allAccounts", in: popup)
        #expect(model.query == query, "Clearing sidebar scope must restore the existing search query")
        model.selection = [item.id]
        popup = try await openNavigation()
        #expect(WorkspaceAuditAccessibility.matching("attachments.sidebar.allAccounts", in: popup).contains { $0.isSelected })
        #expect(WorkspaceAuditAccessibility.matching("attachments.sidebar.allCategories", in: popup).contains { $0.isSelected })
        #expect(model.selection == [item.id], "Reopening the cleared scope must retain the new selection")
        try press("attachments.audit.navigation", in: window)
        try await waitFor("Final navigation dismissal") { !popup.isVisible }
        await app.signOut()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_WORKSPACE_DESIGN_AUDIT_DIR"] != nil))
    func renderCompactTaskEditing() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"), "Task captures use only local synthetic services")
        let suite = "WorkspaceDesignVisualAudit.Tasks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = AccountRecord(id: "task-audit", email: "alex@studio.example", displayName: "Work",
            grantedScopes: [GoogleScopes.tasks], addedAt: .distantPast,
            enabledFeatures: [AccountFeature.tasks.rawValue])
        var request = TaskCreationRequest(title: "Review the revised proposal and confirm the delivery schedule",
            source: TaskEmailSource(accountID: account.id, threadID: "proposal", messageID: "message",
                subject: "Project proposal: revised budget and delivery dates"))
        request.notes = "Check the estimate and confirm the dates with the design team."
        let original = GoogleTask(id: "proposal", title: request.title,
            notes: try request.draft(email: account.email).notes, due: "2026-11-04", etag: "v1")
        let service = WorkspaceVisualTasksService(tasks: [original,
            .init(id: "budget", title: "Confirm the final budget", due: "2026-10-30", parent: original.id),
            .init(id: "notes", title: "Send the meeting notes", status: "completed")])
        let model = GoogleTasksModel(defaults: defaults, loadAccounts: { [account] },
            service: { _ in service }, enable: { _ in })
        await model.refresh()
        defer { model.stop() }
        let controller = NSHostingController(rootView: AnyView(GoogleTasksSidebar(model: model, isActive: false)))
        controller.sizingOptions = []
        let size = NSSize(width: 360, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentViewController = nil }
        try await WorkspaceSupplementCapture.record(window, name: "tasks-compact-sidebar")
        #expect(abs(window.contentLayoutRect.width - size.width) <= 1, "The task sidebar must fit the compact width")

        let session = GoogleTaskEditingSession(model: model, context: .init(task: original,
            location: .init(accountID: account.id, listID: "work"), listTitle: "Work & projects"))
        session.title = "Confirm the revised proposal with the project team"
        controller.rootView = AnyView(ScrollView {
            GoogleTaskEditor(session: session, onFinish: {}).padding(Tokens.Space.s4)
        }.background(Tokens.Surface.canvas))
        try await WorkspaceSupplementCapture.record(window, name: "tasks-compact-inline-editor")
        #expect(!WorkspaceAuditAccessibility.matching("google-task-inline-save", in: window).isEmpty)
        var remote = original
        remote.notes = "The team changed the estimate in Google Tasks.\nReview the new budget before approving delivery."
        remote.due = "2026-11-06"
        remote.etag = "v2"
        await service.replace(remote)
        // End text editing before changing the fixture; native completion UI can
        // otherwise obscure the conflict review in the compositor capture.
        window.makeFirstResponder(nil)
        _ = await session.save() // The local fixture returns 412 to render the real conflict review.
        try #require(session.needsConflictReview)
        try await WorkspaceSupplementCapture.record(window, name: "tasks-compact-conflict")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try #require(descendants(controller.view).compactMap { $0 as? NSScrollView }
            .max { $0.frame.height < $1.frame.height })
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await WorkspaceSupplementCapture.record(window, name: "tasks-compact-conflict-actions")
        for identifier in ["google-task-conflict-use-google", "google-task-conflict-keep-mine", "google-task-inline-cancel"] {
            #expect(WorkspaceAuditAccessibility.matching(identifier, in: window).contains { $0.hasHitTarget(in: window) },
                "Conflict decision must remain reachable: \(identifier)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_WORKSPACE_DESIGN_AUDIT_DIR"] != nil))
    func renderWorkspace() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_WORKSPACE_DESIGN_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let savedAttachmentMode = AttachmentLibraryViewMode.saved
        AttachmentLibraryViewMode.saved = .list
        defer { AttachmentLibraryViewMode.saved = savedAttachmentMode }
        for scheme in [ColorScheme.light, .dark] {
            let host = try await WorkspaceDesignHost(width: 1_280, height: 800, scheme: scheme)
            defer { host.close() }
            await host.app.calendar.seedCalendarAudit()
            let theme = scheme == .light ? "light" : "dark"
            for section in WorkspaceSection.allCases {
                try await host.select(section)
                var attachmentTable: NSTableView?
                if section == .mail, let selected = host.mailbox.listItems.first?.id.threadKey {
                    host.mailbox.selectedThreadIDs = [selected]
                }
                for size in [NSSize(width: 1_280, height: 800), NSSize(width: 720, height: 480)] {
                    host.window.setContentSize(size)
                    try await host.settle()
                    try await host.settle()
                    if section == .attachments {
                        try await host.expectAttachmentControlsVisible()
                        if let attachmentTable {
                            #expect(host.attachmentTable() === attachmentTable,
                                "Resizing the attachment workspace must retain its native collection")
                        } else {
                            attachmentTable = try #require(host.attachmentTable(), "The populated library must have a native list")
                        }
                    }
                    try await host.capture("\(section.rawValue)-\(Int(size.width))-\(theme)", directory: directory)
                }
            }
            try await host.select(.mail)
            for width in [CGFloat(1_079), 1_080, 1_081] {
                host.window.setContentSize(NSSize(width: width, height: 760))
                try await host.settle()
                try await host.settle()
                try await host.capture("mail-breakpoint-\(Int(width))-\(theme)", directory: directory)
            }
            await host.app.signOut()
        }
    }
}

/// UI-audit startup deliberately disables automatic indexing. Prepare the local
/// corpus explicitly, without making captures depend on its background schedule.
@MainActor private func prepareWorkspaceAuditAttachments(_ mailbox: MailboxModel) async throws {
    try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
    try #require(!mailbox.accounts.isEmpty && mailbox.accounts.allSatisfy {
        $0.account.id == "ui-audit" || $0.account.id == "ui-audit-2"
    }, "Only the synthetic workspace accounts may be indexed")
    for owner in mailbox.accounts {
        let state = try await owner.engine.indexAttachments(retryNow: true)
        try #require(state.lastError == nil, "Synthetic attachment indexing must finish without an error")
    }
}

/// Supplemental captures share the workspace output gate and never use a bitmap fallback.
@MainActor private enum WorkspaceSupplementCapture {
    static func record(_ window: NSWindow, name: String) async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_WORKSPACE_DESIGN_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for _ in 0..<3 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        let data = try await NativeWindowCapture.png(of: window)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        Attachment.record(Array(data), named: name + ".png")
    }
}

/// Uses the same in-memory version-conflict pattern as GoogleTaskEditingSessionTests.
private actor WorkspaceVisualTasksService: TasksService {
    private var values: [GoogleTask]
    init(tasks: [GoogleTask]) { values = tasks }
    func replace(_ task: GoogleTask) { values[0] = task }
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage {
        .init(items: [.init(id: "work", title: "Work & projects")])
    }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage { .init(items: values) }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask { throw GmailError.notFound }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask {
        throw GmailError.http(status: 412, reason: nil)
    }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws { throw GmailError.notFound }
}

/// Real hosted controls with synthetic accounts; captures include the native toolbar.
@MainActor private final class WorkspaceDesignHost {
    let app: AppModel
    let mailbox: MailboxModel
    let window: NSWindow
    let controller: NSHostingController<AnyView>
    private let defaults: UserDefaults
    private let suite: String

    init(width: CGFloat, height: CGFloat, scheme: ColorScheme,
         restoredMailbox: MailboxID = .combined(SystemLabel.inbox)) async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"),
            "Workspace design checks require synthetic accounts")
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        app.destination = .mail
        mailbox.restoreMailbox(restoredMailbox)
        let suite = "WorkspaceDesignVisualAudit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(ReadingPreferences.MarkRead.manually.rawValue, forKey: ReadingPreferences.markReadKey)
        let toolbar = "\(MailWindowPreferences.toolbarID).\(UUID().uuidString)"
        let controller = NSHostingController(rootView: AnyView(WorkspaceView(mailbox: mailbox)
            .environment(app).environment(\.workspaceToolbarID, toolbar)
            .environment(\.colorScheme, scheme).defaultAppStorage(defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.autorecalculatesKeyViewLoop = true
        window.orderFront(nil)
        self.app = app
        self.mailbox = mailbox
        self.window = window
        self.controller = controller
        self.defaults = defaults
        self.suite = suite
        try await waitUntil("Synthetic mail and native toolbar") {
            mailbox.accounts.count == 2 && mailbox.accounts.allSatisfy(\.hasSyncedOnce)
                && (mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID
                    || (self.mailTable(pane: .list)?.numberOfRows ?? 0) > 0)
                && window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "workspace.destination" } == true
        }
        try await prepareWorkspaceAuditAttachments(mailbox)
    }

    func close() {
        window.close()
        window.contentViewController = nil
        window.toolbar = nil
        defaults.removePersistentDomain(forName: suite)
    }

    func settle() async throws {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        repeat { try await settle() } while !condition() && ContinuousClock.now < deadline
        try #require(condition(), "\(description)")
    }

    func mailTable(pane: AssistantMailPaneSizing.Pane) -> NSTableView? {
        guard let probe = descendants(controller.view).compactMap({ $0 as? MailColumnProbe.ProbeView })
            .first(where: { $0.pane == pane }) else { return nil }
        var column: NSView = probe
        while let parent = column.superview {
            if let split = parent as? NSSplitView, split.isVertical {
                return descendants(column).compactMap { $0 as? NSTableView }.first
            }
            column = parent
        }
        return nil
    }

    private func attachmentPane() -> NSView? {
        guard let probe = descendants(controller.view).compactMap({ $0 as? AttachmentToolbarInsetProbe.Probe }).first else { return nil }
        var pane: NSView = probe
        while let parent = pane.superview {
            if let split = parent as? NSSplitView, split.isVertical { return pane }
            pane = parent
        }
        return nil
    }

    func attachmentTable() -> NSTableView? {
        attachmentPane().flatMap { descendants($0).compactMap { $0 as? NSTableView }.first }
    }

    func expectAttachmentControlsVisible() async throws {
        var title: WorkspaceAuditAccessibility.Element?
        var filters: WorkspaceAuditAccessibility.Element?
        var coverage: WorkspaceAuditAccessibility.Element?
        var count: WorkspaceAuditAccessibility.Element?
        do {
            try await waitUntil("Attachment heading, Filters, count, and coverage must fit within both window edges") {
                guard let pane = self.attachmentPane() else { return false }
                let elements = WorkspaceAuditAccessibility.elements(in: pane)
                // Inspect the title leaf rather than the padded AX group's union.
                title = elements.filter { $0.label == "Attachments" && !$0.frame(in: self.window).isEmpty }
                    .min { $0.frame(in: self.window).height < $1.frame(in: self.window).height }
                filters = elements.first { $0.label == "Filters" && $0.supportsPress }
                coverage = elements.first { $0.label == "Historical mail indexed" && $0.supportsPress }
                // SwiftUI's plain count Text exposes AXValue, while buttons expose AXLabel.
                count = elements.filter { element in
                    guard element.role == NSAccessibility.Role.staticText.rawValue else { return false }
                    let text = element.label ?? (self.property("accessibilityValue", of: element.object) as? String)
                        ?? (element.object.accessibilityAttributeValue(.value) as? String)
                    return text == "1 attachment" || text?.hasSuffix(" attachments") == true
                }.min { $0.frame(in: self.window).minY < $1.frame(in: self.window).minY }
                return title?.isVisible(in: self.window) == true && filters?.hasHitTarget(in: self.window) == true
                    && coverage?.hasHitTarget(in: self.window) == true && count?.isVisible(in: self.window) == true
            }
        } catch {
            let selected: [(String, WorkspaceAuditAccessibility.Element?)] = [
                ("title", title), ("filters", filters), ("coverage", coverage), ("count", count)
            ]
            var lines = ["Window content layout: \(window.contentLayoutRect)"]
            lines += selected.map { name, element in
                "\(name): \(element?.diagnosticDescription(in: window) ?? "missing")"
            }
            if let pane = attachmentPane() {
                var ancestor: NSView? = pane
                while let view = ancestor {
                    lines.append("ancestor=\(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) windowRect=\(view.convert(view.bounds, to: nil)) safeArea=\(view.safeAreaInsets)")
                    ancestor = view.superview
                }
                if let probe = descendants(pane).compactMap({ $0 as? AttachmentToolbarInsetProbe.Probe }).first {
                    lines.append("measured toolbar inset=\(probe.inset?.top ?? -1)")
                }
                lines += WorkspaceAuditAccessibility.elements(in: pane).compactMap { element in
                    let value = property("accessibilityValue", of: element.object)
                        ?? element.object.accessibilityAttributeValue(.value)
                    guard element.label != nil || value != nil || element.identifier != nil else { return nil }
                    return "label=\(element.label ?? "none") value=\(String(describing: value)) \(element.diagnosticDescription(in: window))"
                }
            } else { lines.append("Attachment pane: missing") }
            let metadata = lines.joined(separator: "\n")
            print("Attachment bounds failure:\n" + metadata)
            Attachment.record(Array(metadata.utf8), named: "attachment-bounds-failure.txt")
            if let directory = ProcessInfo.processInfo.environment["TERN_WORKSPACE_DESIGN_AUDIT_DIR"] {
                try? await capture("attachment-bounds-failure", directory: directory)
            }
            throw error
        }
        let heading = try #require(title)
        let action = try #require(filters)
        let status = try #require(coverage)
        let total = try #require(count)
        #expect(heading.frame(in: window).maxY <= window.contentLayoutRect.maxY + 1)
        #expect(action.frame(in: window).maxY <= window.contentLayoutRect.maxY + 1)
        #expect(status.frame(in: window).minY >= window.contentLayoutRect.minY - 1)
        #expect(total.frame(in: window).minY >= window.contentLayoutRect.minY - 1)
    }

    private func destinationControl() -> NSSegmentedControl? {
        guard let item = window.toolbar?.visibleItems?.first(where: { $0.itemIdentifier.rawValue == "workspace.destination" }),
              !item.isHidden, let view = item.view else { return nil }
        return descendants(view).compactMap { $0 as? NSSegmentedControl }.first {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.segmentCount == WorkspaceSection.allCases.count
        }
    }

    func expectDestinationControl() throws -> NSSegmentedControl {
        let control = try #require(destinationControl(), "All destinations must remain in the native Section toolbar control")
        let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let hit = window.contentView?.superview?.hitTest(point)
        #expect(control.isEnabled && (hit === control || hit?.isDescendant(of: control) == true),
            "The native Section control must be visible and receive clicks")
        return control
    }

    func select(_ section: WorkspaceSection) async throws {
        try await waitUntil("Native Section control") { self.destinationControl() != nil }
        let control = try expectDestinationControl()
        let index = try #require(WorkspaceSection.allCases.firstIndex(of: section))
        control.selectedSegment = index
        let action = try #require(control.action, "The native Section picker must have an action")
        let dispatched = control.sendAction(action, to: control.target)
        try #require(dispatched, "The native Section picker must dispatch its selection")
        try await expectSectionVisible(section)
        #expect(destinationControl()?.selectedSegment == index)
    }

    func expectSectionVisible(_ section: WorkspaceSection) async throws {
        try await waitUntil("The selected \(section.title) workspace must actually receive clicks") {
            switch section {
            case .mail:
                return self.app.destination == .mail && self.mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID
                    && (self.mailTable(pane: .list)?.numberOfRows ?? 0) > 0 && self.mailPaneReceivesClicks(.list)
            case .calendar:
                let calendarSplit = self.descendants(self.controller.view).compactMap { $0 as? NSSplitView }.first {
                    $0.isVertical && !self.descendants($0).contains { $0 is MailColumnProbe.ProbeView || $0 is AttachmentToolbarInsetProbe.Probe }
                }
                return self.app.destination == .calendar && calendarSplit.map { self.contentReceivesClicks($0) } == true
                    && !self.mailPaneReceivesClicks(.list) && !self.mailPaneReceivesClicks(.navigation)
            case .attachments:
                return self.app.destination == .mail && self.mailbox.selectedLabelID == AttachmentLibraryModel.mailboxID
                    && self.attachmentPane().map { self.contentReceivesClicks($0) } == true
                    && !self.mailPaneReceivesClicks(.list) && !self.mailPaneReceivesClicks(.navigation)
            }
        }
        if section == .attachments { try await expectAttachmentControlsVisible() }
    }

    private func mailPaneReceivesClicks(_ pane: AssistantMailPaneSizing.Pane) -> Bool {
        guard let scroll = mailTable(pane: pane)?.enclosingScrollView else { return false }
        return contentReceivesClicks(scroll)
    }

    private func contentReceivesClicks(_ view: NSView) -> Bool {
        guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
        let frame = view.convert(view.bounds, to: nil).intersection(window.contentLayoutRect)
        guard !frame.isEmpty else { return false }
        let point = NSPoint(x: frame.midX, y: frame.midY)
        let hit = window.contentView?.superview?.hitTest(point)
        return hit === view || hit?.isDescendant(of: view) == true
    }

    func capture(_ name: String, directory: String) async throws {
        let data = try await NativeWindowCapture.png(of: window)
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        Attachment.record(Array(data), named: name + ".png")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func property(_ name: String, of object: NSObject) -> Any? {
        object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
    }
}
