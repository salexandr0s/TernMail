import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

/// Hosts production controls with the existing synthetic account fixture.
@Suite(.serialized) @MainActor struct MotionInteractionTests {
    @Test
    func composerDisclosuresKeepFocusAndAttachmentActions() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let id = try #require(await mailbox.startCompose(.newMessage))
        let closer = ComposeWindowCloser()
        let controller = NSHostingController(rootView: ComposeView(localDraftID: id, mailbox: mailbox,
            isEdited: .constant(false), closer: closer, onMove: { _ in })
            .environment(app))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 720))
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentViewController = nil }
        let root = controller.view
        try await until { closer.model?.phase == .open }
        let model = try #require(closer.model)
        try await until {
            self.descendants(root).compactMap { $0 as? RecipientTokenField }
                .contains { $0.accessibilityLabel() == "To" && $0.currentEditor() != nil }
        }
        for (action, label) in [("Add Cc Recipients", "Cc"), ("Add Bcc Recipients", "Bcc")] {
            try press(action, in: root)
            try await until {
                self.descendants(root).compactMap { $0 as? RecipientTokenField }
                    .contains { $0.accessibilityLabel() == label && $0.currentEditor() != nil
                        && $0.currentEditor() === window.firstResponder }
            }
        }
        model.attach([
            .data(Data("Agenda".utf8), filename: "agenda.txt", mimeType: "text/plain"),
            .data(Data("Notes".utf8), filename: "notes.txt", mimeType: "text/plain")
        ])
        try await until { model.attachments.count == 2 }
        try await Task.sleep(for: .milliseconds(40))
        try capture(root, name: "compose-arrival-40ms")
        try await Task.sleep(for: .milliseconds(240))
        try capture(root, name: "compose-attachments")
        try press("Remove agenda.txt", in: root)
        try await until { model.attachments.count == 1 }
        #expect(model.attachments.first?.filename == "notes.txt")
        try await Task.sleep(for: .milliseconds(40))
        try capture(root, name: "compose-removal-40ms")
        try await Task.sleep(for: .milliseconds(240))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: appearance == .aqua ? 640 : 780, height: 720))
            try await Task.sleep(for: .milliseconds(100))
            try capture(root, name: "compose-result-\(appearance.rawValue)")
        }
    }

    @Test
    func mailActionsAndNoticeReplacementStayUsable() async throws {
        try #require(ProcessInfo.processInfo.arguments.contains("--ui-audit"))
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        try await until {
            mailbox.presentedAccounts.count == 2 && mailbox.presentedAccounts.allSatisfy(\.hasSyncedOnce)
        }
        mailbox.selectedMailbox = .account("ui-audit", SystemLabel.inbox)
        try await until { mailbox.isListPresentationReady && !mailbox.listItems.isEmpty }
        let item = try #require(mailbox.listItems.first)
        mailbox.selectListRows([item.id])
        let controller = NSHostingController(rootView: ThreadListView(mailbox: mailbox)
            .modifier(MailNoticeOverlay(mailbox: mailbox))
            .environment(app))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 440, height: 640))
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil }
        try await Task.sleep(for: .milliseconds(200))
        let root = controller.view
        try press(item.thread.isStarred ? "Remove Star" : "Star", in: root, rowSubject: item.thread.subject)
        try await until { mailbox.listItems.first { $0.id == item.id }?.thread.isStarred == !item.thread.isStarred }
        mailbox.notice = .init(message: "Conversation archived", duration: .milliseconds(180))
        try await Task.sleep(for: .milliseconds(40))
        try capture(root, name: "notice-arrival-40ms")
        mailbox.notice = .init(message: "Labels updated", duration: .seconds(10))
        let replacementID = mailbox.notice?.id
        try await Task.sleep(for: .milliseconds(280))
        #expect(mailbox.notice?.id == replacementID, "An exiting notice must not dismiss its replacement")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(100))
            try capture(root, name: "mail-result-\(appearance.rawValue)")
        }
        try press("Dismiss", in: root)
        try await until { mailbox.notice == nil }
    }

    private func until(sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func press(_ label: String, in root: NSView, rowSubject: String? = nil) throws {
        var seen = Set<ObjectIdentifier>()
        var customAction: NSAccessibilityCustomAction?
        let selector = NSSelectorFromString("accessibilityPerformPress")
        func find(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func attribute(_ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
            }
            if let rowSubject,
               (attribute("accessibilityLabel") as? String)?.contains(rowSubject) == true,
               let action = (attribute("accessibilityCustomActions") as? [NSAccessibilityCustomAction])?.first(where: { $0.name == label }) {
                customAction = action
                return object
            }
            if rowSubject == nil, attribute("accessibilityLabel") as? String == label, object.responds(to: selector) { return object }
            let children = attribute("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let result = find(child) { return result }
            }
            return nil
        }
        let object = try #require(find(root), "Missing control: \(label)")
        if let customAction {
            if let handler = customAction.handler {
                try #require(handler())
            } else {
                let target = try #require(customAction.target as? NSObject)
                let action = try #require(customAction.selector)
                let implementation = try #require(target.method(for: action))
                if NSStringFromSelector(action).contains(":") {
                    typealias Invoke = @convention(c) (AnyObject, Selector, NSAccessibilityCustomAction) -> Bool
                    try #require(unsafeBitCast(implementation, to: Invoke.self)(target, action, customAction))
                } else {
                    typealias Invoke = @convention(c) (AnyObject, Selector) -> Bool
                    try #require(unsafeBitCast(implementation, to: Invoke.self)(target, action))
                }
            }
            return
        }
        let implementation = try #require(object.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        try #require(unsafeBitCast(implementation, to: Press.self)(object, selector))
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name + ".png")
    }
}
