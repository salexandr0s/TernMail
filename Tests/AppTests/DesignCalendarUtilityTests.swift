import AppKit
import GmailAPI
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct DesignCalendarUtilityTests {
    @Test func allocationReservesBothMinimumsWithoutChangingThePreference() {
        let boundary = Tokens.Calendar.contentMinWidth + Tokens.Assistant.sidebarMinWidth + Tokens.Border.hairline
        for width in [CGFloat(720), boundary - 1, boundary, 900, 1_200] {
            let layout = CalendarUtilityLayout(availableWidth: width, preferredWidth: 480, isPresented: true)
            #expect(layout.isCompact == (width < boundary))
            if layout.isCompact {
                #expect(layout.calendarWidth == width)
                #expect(layout.utilityWidth == width)
            } else {
                #expect(layout.calendarWidth >= Tokens.Calendar.contentMinWidth)
                #expect(layout.utilityWidth >= Tokens.Assistant.sidebarMinWidth)
                #expect(layout.utilityWidth <= 480)
                #expect(layout.calendarWidth + layout.utilityWidth + Tokens.Border.hairline == width)
            }
        }
        let closed = CalendarUtilityLayout(availableWidth: 720, preferredWidth: 480, isPresented: false)
        #expect(closed.calendarWidth == 720)
        #expect(closed.utilityWidth == 0)
        #expect(!closed.isCompact)
    }

    @Test(.timeLimit(.minutes(1))) func workspaceResizesTasksAndAssistantWithoutLosingInputOrCalendarSpace() async throws {
        let app = AppModel()
        await app.start()
        await app.calendar.start()
        await app.calendar.seedCalendarAudit()
        let mailbox = try #require(app.mailbox)
        let suite = "DesignCalendarWorkspace-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(480.0, forKey: AssistantSidebarLayout.widthKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        app.destination = .calendar
        let controller = NSHostingController(rootView: WorkspaceView(mailbox: mailbox).environment(app)
            .environment(\.workspaceToolbarID, MailWindowPreferences.toolbarID + "." + UUID().uuidString)
            .defaultAppStorage(defaults))
        let window = host(controller, width: 900, toolbar: true)
        defer { window.close(); window.contentViewController = nil; window.toolbar = nil }
        try await settle(window)
        try await until { self.calendarSplit(in: controller.view) != nil }
        try await pressToolbar("workspace.tasks", in: window)
        _ = try await requireElement(id: "google-tasks-sidebar", in: controller.view, window: window)

        for width in [CGFloat(900), 741, 720, 900] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await settle(window)
            #expect(abs(controller.view.bounds.width - width) <= 1, "The hosted workspace must reach the requested content width")
            let layout = CalendarUtilityLayout(availableWidth: width, preferredWidth: 480, isPresented: true)
            let split = try #require(calendarSplit(in: controller.view))
            #expect(abs(split.frame.width - layout.calendarWidth) <= 1)
            let tasks = try #require(element(id: "google-tasks-sidebar", in: controller.view))
            let tasksFrame = try accessibilityFrame(tasks)
            #expect(abs(tasksFrame.width - layout.utilityWidth) <= 1)
            #expect(defaults.double(forKey: AssistantSidebarLayout.widthKey) == 480)
            let back = element(id: "calendar-utility-back", in: controller.view)
            #expect((back != nil) == layout.isCompact)
            if layout.isCompact {
                let visible = Set(window.toolbar?.visibleItems?.map { $0.itemIdentifier.rawValue } ?? [])
                for identifier in ["workspace.sidebar", "workspace.search", "mail.compose",
                                   "calendar.navigation", "calendar.today", "calendar.mode"] {
                    #expect(!visible.contains(identifier), "Calendar command \(identifier) must hide while its utility fills the workspace")
                }
                try capture(controller.view, name: "calendar-tasks-compact-720")
            } else if width == 900 {
                #expect(split.frame.width >= Tokens.Calendar.contentMinWidth - 1)
                try capture(controller.view, name: "calendar-tasks-adjacent-900")
            }
        }
        // Search results own native List focus independently of the time grid.
        app.calendar.searchText = "Project review"
        try await until { !app.calendar.searchResults.isEmpty }
        let editableResult = app.calendar.searchResults.first { $0.canEdit }
        let selectedResult = try #require(editableResult)
        app.calendar.selectedEventID = selectedResult.id
        try await settle(window)
        let detail = try #require(calendarSplit(in: controller.view)?.arrangedSubviews.last)
        let populatedTable = descendants(detail).compactMap { $0 as? NSTableView }.first { $0.numberOfRows > 0 }
        let results = try #require(populatedTable)
        try #require(window.makeFirstResponder(results))
        try await settle(window)
        #expect(window.firstResponder === results)
        window.setContentSize(NSSize(width: 720, height: 700))
        try await settle(window)
        let back = try #require(element(id: "calendar-utility-back", in: controller.view))
        let nativeResponder = window.firstResponder as? NSView
        let calendar = try #require(calendarSplit(in: controller.view))
        #expect(attribute("accessibilityFocused", of: back) as? Bool == true
            || (nativeResponder != nil && nativeResponder?.isDescendant(of: calendar) == false))
        #expect(window.firstResponder !== results)
        try sendReturn(to: window)
        try await settle(window)
        #expect(app.calendar.editor == nil, "Return after hiding focused Calendar results must not edit a hidden event")
        // Return may activate the focused Back button; otherwise use its action.
        if element(id: "google-tasks-sidebar", in: controller.view) != nil {
            let closeButton = try #require(element(id: "calendar-utility-back", in: controller.view))
            try #require(press(closeButton))
        }
        try await until { self.element(id: "google-tasks-sidebar", in: controller.view) == nil }
        app.calendar.searchText = ""
        try await settle(window)
        let closedCalendar = try #require(calendarSplit(in: controller.view))
        #expect(abs(closedCalendar.frame.width - 720) <= 1)
        try capture(controller.view, name: "calendar-closed-720")

        window.setContentSize(NSSize(width: 900, height: 700))
        try await settle(window)
        let assistant = app.assistant
        assistant.composerText = "Keep this unfinished calendar question."
        try await pressToolbar("workspace.assistant", in: window)
        try await until { self.element(id: "assistant.message", in: controller.view) != nil }
        for width in [CGFloat(900), 741, 720, 900] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await settle(window)
            #expect(app.assistant === assistant)
            #expect(assistant.composerText == "Keep this unfinished calendar question.")
            let input = try #require(element(id: "assistant.message", in: controller.view))
            #expect(attribute("accessibilityValue", of: input) as? String == assistant.composerText)
            #expect(defaults.double(forKey: AssistantSidebarLayout.widthKey) == 480)
        }
        try capture(controller.view, name: "calendar-assistant-restored-900")
        await app.signOut()
    }

    @Test(.timeLimit(.minutes(1))) func retainedUtilityKeepsNativeTaskEditorsAndProtectsInlineDraftFromClosure() async throws {
        let suite = "DesignCalendarTasks-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = AccountRecord(id: "calendar-task-layout", email: "tasks@example.invalid", displayName: "Tasks",
            grantedScopes: [GoogleScopes.tasks], addedAt: .distantPast, enabledFeatures: [AccountFeature.tasks.rawValue])
        let service = CalendarUtilityTasksService()
        let model = GoogleTasksModel(defaults: defaults, loadAccounts: { [account] }, service: { _ in service }, enable: { _ in })
        await model.refresh()
        defer { model.stop() }
        var closeCount = 0
        let controller = NSHostingController(rootView: CalendarTasksUtilityHarness(model: model, onClose: { closeCount += 1 }))
        let window = host(controller, width: 900)
        defer { window.close(); window.contentViewController = nil }
        try await settle(window)
        try await until { self.field(placeholder: "Add a task…", in: controller.view) != nil }
        let quickTitle = try #require(field(placeholder: "Add a task…", in: controller.view))
        try #require(window.makeFirstResponder(quickTitle))
        let quickEditor = try #require(quickTitle.currentEditor() as? NSTextView)
        quickEditor.insertText("Unsubmitted new task", replacementRange: NSRange(location: 0, length: quickEditor.string.utf16.count))
        try await until { quickTitle.stringValue == "Unsubmitted new task" }
        // The title is the always-visible edit action; the pencil appears on hover.
        let editButton = try #require(element(id: "google-task-edit-edited", in: controller.view))
        try #require(press(editButton))
        try await until {
            self.field(placeholder: "What needs to be done?", in: controller.view)?.currentEditor() === window.firstResponder
                && window.firstResponder is NSTextView
        }
        let title = try #require(field(placeholder: "What needs to be done?", in: controller.view))
        let editor = try #require(title.currentEditor() as? NSTextView)
        editor.insertText("Unsaved inline calendar task", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await until { editor.string == "Unsaved inline calendar task" }
        for width in [CGFloat(900), 741, 720, 900] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await settle(window)
            #expect(abs(controller.view.bounds.width - width) <= 1, "The retained utility must reach the requested content width")
            #expect(field(placeholder: "Add a task…", in: controller.view) === quickTitle)
            #expect(quickTitle.stringValue == "Unsubmitted new task")
            #expect(field(placeholder: "What needs to be done?", in: controller.view) === title)
            #expect(window.firstResponder === editor)
            #expect(editor.string == "Unsaved inline calendar task")
            if width == 720 {
                let back = try await requireElement(id: "calendar-utility-back", in: controller.view, window: window)
                #expect(attribute("accessibilityEnabled", of: back) as? Bool == false)
                _ = press(back)
                #expect(closeCount == 0)
                try capture(controller.view, name: "calendar-tasks-inline-draft-compact")
            }
        }
        let cancelButton = try #require(element(id: "google-task-inline-cancel", in: controller.view))
        try #require(press(cancelButton))
        try await until { self.element(id: "google-task-title", in: controller.view) == nil }
        window.setContentSize(NSSize(width: 720, height: 700))
        try await settle(window)
        let back = try await requireElement(id: "calendar-utility-back", in: controller.view, window: window)
        #expect(attribute("accessibilityEnabled", of: back) as? Bool == true)
        try #require(press(back))
        #expect(closeCount == 1)
    }

    private func host<Content: View>(_ controller: NSHostingController<Content>, width: CGFloat, toolbar: Bool = false) -> NSWindow {
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if toolbar { window.toolbarStyle = .unified }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 700))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(160))
    }

    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func field(placeholder: String, in root: NSView) -> NSTextField? {
        descendants(root).compactMap { $0 as? NSTextField }.first { $0.placeholderString == placeholder }
    }

    private func calendarSplit(in root: NSView) -> NSSplitView? {
        descendants(root).compactMap { $0 as? NSSplitView }.first { split in
            split.isVertical && !descendants(split).contains { $0 is MailColumnProbe.ProbeView }
        }
    }

    private func attribute(_ name: String, of object: NSObject) -> Any? {
        let getter = name == "accessibilityEnabled" ? "isAccessibilityEnabled"
            : name == "accessibilityFocused" ? "isAccessibilityFocused" : name
        if object.responds(to: NSSelectorFromString(getter)), let value = object.value(forKey: getter) { return value }
        let legacy: NSAccessibility.Attribute?
        switch name {
        case "accessibilityChildren": legacy = .children
        case "accessibilityIdentifier": legacy = .identifier
        case "accessibilityLabel": legacy = .description
        case "accessibilityRole": legacy = .role
        case "accessibilityValue": legacy = .value
        case "accessibilityEnabled": legacy = .enabled
        case "accessibilityFocused": legacy = .focused
        default: legacy = nil
        }
        return legacy.flatMap { legacyAttribute($0, of: object) }
    }

    private func legacyAttribute(_ name: NSAccessibility.Attribute, of object: NSObject) -> Any? {
        guard object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return object.accessibilityAttributeValue(name)
    }

    private func actions(of object: NSObject) -> [NSAccessibility.Action] {
        guard object.responds(to: NSSelectorFromString("accessibilityActionNames")) else { return [] }
        return object.accessibilityActionNames()
    }

    private func accessibilityFrame(_ object: NSObject) throws -> NSRect {
        if let value = attribute("accessibilityFrame", of: object) as? NSValue { return value.rectValue }
        let position = try #require(legacyAttribute(.position, of: object) as? NSValue)
        let size = try #require(legacyAttribute(.size, of: object) as? NSValue)
        return NSRect(origin: position.pointValue, size: size.sizeValue)
    }

    private func element(id: String? = nil, role: String? = nil, in root: NSView) -> NSObject? {
        let matches = accessibilityObjects(root).filter {
            (id == nil || attribute("accessibilityIdentifier", of: $0) as? String == id)
                && (role == nil || attribute("accessibilityRole", of: $0) as? String == role)
        }
        return matches.first { attribute("accessibilityRole", of: $0) as? String == NSAccessibility.Role.button.rawValue }
            ?? matches.first
    }

    private func accessibilityObjects(_ root: Any) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var objects: [NSObject] = []
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            objects.append(object)
            let children = attribute("accessibilityChildren", of: object) as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                visit(child)
            }
        }
        visit(root)
        return objects
    }

    private func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let objects = accessibilityObjects(object)
        let candidates = Array(objects.dropFirst()) + [object]
        for candidate in candidates {
            let role = attribute("accessibilityRole", of: candidate) as? String
            let actions = actions(of: candidate)
            guard role == NSAccessibility.Role.button.rawValue || role == NSAccessibility.Role.menuButton.rawValue
                    || actions.contains(.press), attribute("accessibilityEnabled", of: candidate) as? Bool != false else { continue }
            if candidate.responds(to: selector), let implementation = candidate.method(for: selector) {
                // AppKit's public BOOL accessibilityPerformPress selector.
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                if unsafeBitCast(implementation, to: Press.self)(candidate, selector) { return true }
            }
            if actions.contains(.press), candidate.responds(to: NSSelectorFromString("accessibilityPerformAction:")) {
                candidate.accessibilityPerformAction(.press)
                return true
            }
        }
        print("TERN_CALENDAR_PRESS_FAILED " + diagnostic(object))
        return false
    }

    private func pressToolbar(_ identifier: String, in window: NSWindow) async throws {
        try await until { window.toolbar?.visibleItems?.contains { $0.itemIdentifier.rawValue == identifier && $0.view?.window === window } == true }
        let matchingItem = window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == identifier }
        let item = try #require(matchingItem)
        let view = try #require(item.view)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        #expect(window.contentView?.superview?.hitTest(point)?.isDescendant(of: view) == true)
        try #require(press(view))
    }

    private func requireElement(id: String, in root: NSView, window: NSWindow) async throws -> NSObject {
        let deadline = ContinuousClock.now + .seconds(5)
        while element(id: id, in: root) == nil, ContinuousClock.now < deadline {
            try await settle(window)
        }
        if element(id: id, in: root) == nil {
            try? capture(root, name: "calendar-missing-" + id)
            let toolbar = window.toolbar?.visibleItems?.map { $0.itemIdentifier.rawValue }.joined(separator: ",") ?? "none"
            let tree = accessibilityObjects(window.contentView?.superview ?? root).filter {
                attribute("accessibilityIdentifier", of: $0) != nil || attribute("accessibilityRole", of: $0) != nil
            }.prefix(100).map(diagnostic).joined(separator: "\n")
            let report = "Missing \(id); active=\(NSApp.isActive); key=\(window.isKeyWindow); window=\(window.frame); content=\(root.bounds); toolbar=\(toolbar)\n" + tree
            print("TERN_CALENDAR_AX_FAILURE\n" + report)
            Attachment.record(Array(report.utf8), named: "calendar-missing-" + id + ".txt")
        }
        let found = element(id: id, in: root)
        return try #require(found)
    }

    private func diagnostic(_ object: NSObject) -> String {
        let id = attribute("accessibilityIdentifier", of: object) as? String ?? "-"
        let role = attribute("accessibilityRole", of: object) as? String ?? "-"
        let label = String((attribute("accessibilityLabel", of: object) as? String ?? "-").prefix(80))
        let enabled = attribute("accessibilityEnabled", of: object).map(String.init(describing:)) ?? "-"
        let frame = attribute("accessibilityFrame", of: object).map(String.init(describing:)) ?? "-"
        let actions = actions(of: object).map(\.rawValue).joined(separator: ",")
        return "\(type(of: object)) id=\(id) role=\(role) label=\(label) enabled=\(enabled) frame=\(frame) actions=\(actions)"
    }

    private func sendReturn(to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(event)
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name + ".png")
    }
}

private struct CalendarTasksUtilityHarness: View {
    let model: GoogleTasksModel
    let onClose: () -> Void
    @State private var canClose = true
    @FocusState private var backFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let layout = CalendarUtilityLayout(availableWidth: geometry.size.width, preferredWidth: 480, isPresented: true)
            ZStack(alignment: .topLeading) {
                Color.clear
                CalendarUtilityPanel(layout: layout, height: geometry.size.height, title: "Tasks", canClose: canClose,
                    backFocused: $backFocused, onBack: onClose, onResize: { _ in }) {
                    ZStack {
                        GoogleTasksSidebar(model: model, onClose: onClose, isActive: false,
                            onCloseAvailabilityChange: { canClose = $0 })
                    }
                }
            }
        }
    }
}

private actor CalendarUtilityTasksService: TasksService {
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage { .init(items: [.init(id: "list", title: "Review")]) }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage {
        .init(items: [GoogleTask(id: "edited", title: "Review the proposal")])
    }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask { throw GmailError.notFound }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask { throw GmailError.notFound }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws { throw GmailError.notFound }
}
