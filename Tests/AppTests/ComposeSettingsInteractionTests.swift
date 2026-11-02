import AppKit
import MailStore
import MessageContent
import SwiftUI
import Testing
@testable import Tern

/// Drives only controls hosted by this test. No global keyboard or mouse events,
/// Accessibility permission, account data, or UI-test automation service is used.
@Suite(.serialized) @MainActor struct ComposeSettingsInteractionTests {
    @Test(arguments: [false, true])
    func templateNavigationPreservesNativeEditsUntilDiscard(selectSaved: Bool) async throws {
        let store = try AccountStore.inMemory()
        let saved = ComposeTemplate(id: "saved", name: "Saved template",
            document: ComposeDocument(plainText: "Saved message"))
        try await store.saveComposeTemplate(saved)
        let unsaved = SettingsUnsavedChanges()
        let controller = NSHostingController(rootView: ComposeTemplatesPane(store: store).environment(unsaved))
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 680))
        window.orderFront(nil)
        defer { window.close() }
        let root = controller.view
        try await waitFor(root) {
            self.nameField(in: root) != nil && self.messageEditor(in: root) != nil
                && self.element("compose-template-new", in: root) != nil
                && self.element("compose-template-selection." + saved.id, in: root) != nil
        }
        let name = try #require(nameField(in: root))
        let body = try #require(messageEditor(in: root))

        // Go through NSTextField's real field editor and NSTextView's input
        // path so the production bindings, delegates, and dirty tracking run.
        name.selectText(nil)
        let fieldEditor = try #require(window.fieldEditor(false, for: name) as? NSTextView,
            "The hosted name field must provide its native field editor.")
        fieldEditor.insertText("Unsaved template", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        try #require(window.makeFirstResponder(body))
        body.insertText("Unsaved message", replacementRange: NSRange(location: 0, length: body.string.utf16.count))
        try await waitFor(root) {
            unsaved.subject == "template" && name.stringValue == "Unsaved template"
                && body.string.trimmingCharacters(in: .whitespacesAndNewlines) == "Unsaved message"
        }

        func requestNavigation() throws {
            if selectSaved {
                let savedRow = try #require(element("compose-template-selection." + saved.id, in: root),
                    "The saved template must expose its library action.")
                try #require(press(savedRow))
            } else {
                let button = try #require(element("compose-template-new", in: root))
                try #require(press(button))
            }
        }

        try requestNavigation()
        try await waitFor(root) { unsaved.pendingChange != nil }
        #expect(unsaved.pendingChange?.subject == "template")
        #expect(name.stringValue == "Unsaved template")
        #expect(body.string.trimmingCharacters(in: .whitespacesAndNewlines) == "Unsaved message")

        // These are the shared gate's production Cancel and Discard actions.
        // The SettingsView confirmation dialog itself is not mounted here.
        unsaved.pendingChange = nil
        try await waitFor(root) { unsaved.pendingChange == nil }
        #expect(unsaved.subject == "template")
        #expect(name.stringValue == "Unsaved template")
        #expect(body.string.trimmingCharacters(in: .whitespacesAndNewlines) == "Unsaved message")

        try requestNavigation()
        try await waitFor(root) { unsaved.pendingChange != nil }
        unsaved.discardAndApply(try #require(unsaved.pendingChange))
        try await waitFor(root) {
            unsaved.subject == nil && unsaved.pendingChange == nil
                && name.stringValue == (selectSaved ? saved.name : "")
                && body.string.trimmingCharacters(in: .whitespacesAndNewlines) == (selectSaved ? "Saved message" : "")
        }
        #expect(try await store.composeTemplates() == [saved])
    }

    private func nameField(in root: NSView) -> NSTextField? {
        descendants(in: root).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.placeholderString == "Template name" }
    }

    private func messageEditor(in root: NSView) -> ComposeTextView? {
        descendants(in: root).compactMap { $0 as? ComposeTextView }.first
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func waitFor(_ root: NSView, sourceLocation: SourceLocation = #_sourceLocation,
                         _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            root.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(predicate(), sourceLocation: sourceLocation)
    }

    private func element(_ id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) -> NSObject? {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func attribute(_ name: String) -> Any? {
                object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil
            }
            if attribute("accessibilityIdentifier") as? String == id { return object }
            let children = attribute("accessibilityChildren") as? [Any] ?? []
            for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                if let result = visit(child) { return result }
            }
            return nil
        }
        return visit(root)
    }

    private func press(_ object: NSObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
        // SwiftUI nodes expose the public BOOL selector without formal
        // NSAccessibility protocol conformance, as in existing hosted tests.
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Press.self)(object, selector)
    }
}
