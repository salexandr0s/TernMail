import AppKit
import GmailAPI
import MailStore
import SwiftUI
import Testing
@testable import Tern

/// Native controls backed by local cache records and synthetic task services.
@Suite(.serialized) @MainActor struct DesignInteractionTests {
    @Test(arguments: [false, true])
    func spacePassesThroughWithoutChangingReadState(conversations: Bool) async throws {
        let mailbox = try await mailbox()
        defer { Task { await mailbox.stop() } }
        mailbox.listPreferences.conversations = conversations
        try await until { mailbox.listItems.count == 2 }
        var passedSpaces = 0
        let controller = NSHostingController(rootView: VStack {
            ThreadListView(mailbox: mailbox)
        }
        .onKeyPress(.space) { passedSpaces += 1; return .handled }
        .environment(AppModel()))
        let window = host(controller, size: NSSize(width: 440, height: 520))
        defer { window.close(); window.contentViewController = nil }
        try await until { self.descendants(controller.view).contains { $0 is NSTableView } }
        let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        try #require(window.makeFirstResponder(table))
        let original = mailbox.listItems
        for count in [1, 2] {
            mailbox.selectListRows(Set(original.prefix(count).map(\.id)))
            try sendKey(" ", code: 49, to: window)
            try await until { passedSpaces == count }
            #expect(mailbox.listItems.map(\.thread.isUnread) == original.map(\.thread.isUnread))
            #expect(mailbox.selectedListRowIDs == Set(original.prefix(count).map(\.id)))
            #expect(mailbox.notice == nil)
        }
    }

    @Test
    func errorsPersistWhileInformationAndSendCancellationStillExpire() async throws {
        let mailbox = try await mailbox()
        defer { Task { await mailbox.stop() } }
        let controller = NSHostingController(rootView: Color.clear
            .modifier(MailNoticeOverlay(mailbox: mailbox)))
        let window = host(controller, size: NSSize(width: 500, height: 260))
        defer { window.close(); window.contentViewController = nil }
        // Keep the pointer out of the notice so the informational timer runs.
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        mailbox.notice = .init(message: "Saved the file", duration: .milliseconds(100))
        try await until { mailbox.notice == nil }
        mailbox.notice = .init(message: "Older confirmation", duration: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(30))
        mailbox.notice = .init(message: "Couldn't save the file. Try another folder.", isError: true,
                               duration: .milliseconds(100))
        let errorID = mailbox.notice?.id
        mailbox.didQueueSend("synthetic-deadline", delay: 0.12)
        try await Task.sleep(for: .milliseconds(280))
        #expect(mailbox.notice?.id == errorID, "An error must outlast its timer and the previous notice's timer")
        #expect(mailbox.undoableSendID == nil, "A persistent error must not extend Undo Send")
        // The synthetic draft has no engine completion event to remove its notice.
        mailbox.sendNotice = nil
        try await Task.sleep(for: .milliseconds(300))
        try capture(controller.view, name: "design-error-persistent")
        let dismiss = try #require(element(label: "Dismiss", in: controller.view))
        try #require(press(dismiss))
        try await until { mailbox.notice == nil }
    }

    @Test
    func attachmentGridKeepsFocusSeparateFromSelection() async throws {
        let mailbox = try await mailbox(attachments: true)
        defer { Task { await mailbox.stop() } }
        let model = AttachmentLibraryModel(mailbox: mailbox)
        let observing = Task { await model.reload() }
        defer { observing.cancel() }
        try await until { model.items.count == 2 }
        let first = try #require(model.items.first)
        let second = try #require(model.items.last)
        let card = AttachmentLibraryCard(item: first, accountName: model.accountName(first),
            accounts: model.availableAccounts, selected: true)
        let focusedCard = AttachmentLibraryCard(item: first, accountName: model.accountName(first),
            accounts: model.availableAccounts, selected: true, isKeyboardTarget: true)
        #expect(card != focusedCard, "Equatable must let focus changes redraw a selected card")
        let controller = NSHostingController(rootView: VStack {
            AttachmentLibraryCollection(model: model, viewMode: .grid, availableWidth: 560)
            TextField("Outside grid", text: .constant(""))
                .accessibilityIdentifier("design-focus-outside").padding()
        }.background(Tokens.Surface.canvas))
        let window = host(controller, size: NSSize(width: 560, height: 470))
        defer { window.close(); window.contentViewController = nil }
        window.appearance = NSAppearance(named: .aqua)
        let label = AttachmentPresentation.accessibilityLabel(first, account: model.accountName(first))
        try await until { self.element(label: label, in: controller.view) != nil }
        try #require(press(try #require(element(label: label, in: controller.view))))
        try await until { model.selection == [first.id] }
        try sendKey("\u{1b}", code: 53, to: window)
        try await until { model.selection.isEmpty }
        try capture(controller.view, name: "design-grid-focused-no-selection-light")
        try sendKey("\u{F703}", code: 124, modifiers: [.function, .numericPad, .shift], to: window)
        try await until { model.selection == [first.id, second.id] }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(80))
            try capture(controller.view, name: "design-grid-focused-selected-\(appearance.rawValue)")
        }
        let outside = try #require(descendants(controller.view).compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Outside grid" })
        try #require(window.makeFirstResponder(outside))
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.selection == [first.id, second.id])
        try capture(controller.view, name: "design-grid-inactive-selected-dark")
    }

    @Test(arguments: [false, true])
    func taskRefreshKeepsOpenAndCompletedInlineDrafts(completed: Bool) async throws {
        let suite = "DesignInteractionTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = AccountRecord(id: "design-tasks", email: "tasks@example.invalid", displayName: "Tasks",
            grantedScopes: [GoogleScopes.tasks], addedAt: .distantPast,
            enabledFeatures: [AccountFeature.tasks.rawValue])
        let service = DesignInteractionTasksService(completed: completed)
        let model = GoogleTasksModel(defaults: defaults, loadAccounts: { [account] },
            service: { _ in service }, enable: { _ in })
        await model.refresh()
        defer { model.stop() }
        var closeAvailability: [Bool] = []
        let controller = NSHostingController(rootView: GoogleTasksSidebar(model: model, isActive: false,
            onCloseAvailabilityChange: { closeAvailability.append($0) }))
        let window = host(controller, size: NSSize(width: 320, height: 680))
        defer { window.close(); window.contentViewController = nil }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutSubtreeIfNeeded()
        try await until { closeAvailability == [true] }
        if completed {
            try await until { self.element(id: "google-tasks-completed-toggle", in: controller.view) != nil }
            try #require(press(try #require(element(id: "google-tasks-completed-toggle", in: controller.view))))
        }
        try await until { self.element(id: "google-task-edit-edited", in: controller.view) != nil }
        let edit = try #require(element(id: "google-task-edit-edited", in: controller.view))
        try #require(press(edit), "Task edit control: \(accessibilitySummary(edit))")
        try await until { window.firstResponder is NSTextView }
        do {
            try await until { closeAvailability == [true, false] }
        } catch {
            print("TERN_DESIGN_TASK_EDIT_FAILED \(accessibilitySummary(edit))")
            throw error
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("Unsaved review notes", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await until { editor.string == "Unsaved review notes" }
        // A refresh can remove or reclassify a task while its draft is open.
        model.tasks = [GoogleTask(id: "other", title: "Another task")]
        try await Task.sleep(for: .milliseconds(120))
        #expect(window.firstResponder === editor)
        #expect(editor.string == "Unsaved review notes")
        #expect(element(id: "google-task-title", in: controller.view) != nil)
        #expect(closeAvailability == [true, false], "Refresh must keep the editing sidebar protected from closure")
        try capture(controller.view, name: "design-task-\(completed ? "completed" : "open")-draft-retained")
        try sendKey("\u{1b}", code: 53, to: window)
        try await until { self.element(id: "google-task-title", in: controller.view) == nil }
        try await until { closeAvailability == [true, false, true] }
    }

    private func mailbox(attachments: Bool = false) async throws -> MailboxModel {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            for index in 0..<2 {
                let message = MessageRecord(accountID: "design-interactions", id: "m\(index)", threadID: "t\(index)",
                    historyID: 1, date: Date(timeIntervalSince1970: Double(index)), snippet: "Review notes",
                    sender: "Alex <alex@example.invalid>", recipients: "owner@example.invalid", cc: nil,
                    subject: "Review \(index)", sizeEstimate: 32)
                try tx.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox, SystemLabel.unread])])
                if attachments {
                    let file = AttachmentRecord(accountID: message.accountID, messageID: message.id, partID: "1",
                        attachmentID: nil, filename: "review-\(index).txt", mimeType: "text/plain", size: 32, isInline: false)
                    try tx.replaceLibraryAttachments([file], message: message, labelIDs: [SystemLabel.inbox, SystemLabel.unread])
                }
            }
            try tx.rebuildThreads(["t0", "t1"], accountID: "design-interactions")
        }
        let account = AccountRecord(id: "design-interactions", email: "owner@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .distantPast)
        let suite = "DesignInteractionMailbox-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        // This suite only holds in-memory view preferences during the fixture.
        defer { defaults.removePersistentDomain(forName: suite) }
        let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory, syncEnabled: false,
            listPreferences: MessageListPreferences(defaults: defaults))
        await mailbox.start()
        try await until { mailbox.isListPresentationReady && mailbox.listItems.count == 2 }
        return mailbox
    }

    private func host<Content: View>(_ controller: NSHostingController<Content>, size: NSSize) -> NSWindow {
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func sendKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func element(id: String? = nil, label: String? = nil, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        var matches: [NSObject] = []
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if (id == nil || accessibilityValue("accessibilityIdentifier", of: object) as? String == id),
               (label == nil || accessibilityValue("accessibilityLabel", of: object) as? String == label) { matches.append(object) }
            let children = accessibilityValue("accessibilityChildren", of: object) as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                visit(child)
            }
        }
        visit(root)
        // SwiftUI can attach the same identifier to a wrapper and its button.
        return matches.first { accessibilityValue("accessibilityRole", of: $0) as? String == NSAccessibility.Role.button.rawValue }
            ?? matches.first
    }

    private func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if object.responds(to: selector), let implementation = object.method(for: selector) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            if unsafeBitCast(implementation, to: Press.self)(object, selector) { return true }
        }
        if accessibilityActions(object).contains(.press),
           object.responds(to: NSSelectorFromString("accessibilityPerformAction:")) {
            object.accessibilityPerformAction(.press)
            return true
        }
        // Some identifiers belong to an AX group around the native control.
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(object)]
        func descendantButton(_ value: Any) -> NSObject? {
            guard let child = value as? NSObject, seen.insert(ObjectIdentifier(child)).inserted else { return nil }
            if accessibilityValue("accessibilityRole", of: child) as? String == NSAccessibility.Role.button.rawValue { return child }
            let children = accessibilityValue("accessibilityChildren", of: child) as? [Any] ?? []
            return (children + NSAccessibility.unignoredChildren(from: children) + ((child as? NSView)?.subviews ?? []))
                .lazy.compactMap(descendantButton).first
        }
        let children = accessibilityValue("accessibilityChildren", of: object) as? [Any] ?? []
        if let button = (children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []))
            .lazy.compactMap(descendantButton).first { return press(button) }
        return false
    }

    private func accessibilityValue(_ key: String, of object: NSObject) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    private func accessibilityActions(_ object: NSObject) -> [NSAccessibility.Action] {
        guard object.responds(to: NSSelectorFromString("accessibilityActionNames")) else { return [] }
        return object.accessibilityActionNames()
    }

    private func accessibilitySummary(_ object: NSObject) -> String {
        let children = accessibilityValue("accessibilityChildren", of: object) as? [Any] ?? []
        let description = ["accessibilityIdentifier", "accessibilityLabel", "accessibilityRole", "accessibilityEnabled", "accessibilityFrame"]
            .map { "\($0)=\(String(describing: accessibilityValue($0, of: object)))" }.joined(separator: ", ")
        return "\(type(of: object)): \(description), actions=\(accessibilityActions(object)), children=\(children.count)"
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name + ".png")
    }
}

private actor DesignInteractionTasksService: TasksService {
    let completed: Bool
    init(completed: Bool) { self.completed = completed }
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage {
        .init(items: [.init(id: "list", title: "Review")])
    }
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage {
        .init(items: [GoogleTask(id: "edited", title: "Review the proposal", status: completed ? "completed" : "needsAction"),
                      GoogleTask(id: "other", title: "Another task")])
    }
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask { throw GmailError.notFound }
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask { throw GmailError.notFound }
    func deleteTask(listID: String, taskID: String, etag: String?) async throws { throw GmailError.notFound }
}
