import AppKit
import MailStore
import MessageContent
import SwiftUI
import Testing
@testable import Tern

/// Production compose windows with isolated preferences, in-memory mail and a local Gmail service.
@Suite(.serialized) @MainActor struct DesignComposeVisualAudit {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERN_DESIGN_COMPOSE_AUDIT_DIR"] != nil))
    func captureShortAndNarrowComposeOverflow() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["TERN_DESIGN_COMPOSE_AUDIT_DIR"])
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fixture = try await Fixture.make()
        defer { fixture.dispose() }
        try await fixture.stress()
        for (name, size, appearance) in [
            ("minimum-light", NSSize(width: 480, height: 360), NSAppearance.Name.aqua),
            ("narrow-dark", NSSize(width: 480, height: 540), .darkAqua),
            ("wide-light", NSSize(width: 800, height: 600), .aqua)
        ] {
            fixture.window.appearance = NSAppearance(named: appearance)
            fixture.window.setContentSize(size)
            try await fixture.settle()
            try fixture.assertWritingViewport()
            try fixture.capture(directory: directory, name: name)
            let bcc = try fixture.recipient("Bcc")
            try await fixture.focusRecipient(bcc)
            try fixture.assertCaretVisible(in: bcc)
            try fixture.capture(directory: directory, name: name + "-bcc-focus")
            try fixture.scrollSupplementsToBottom()
            try await fixture.settle()
            try fixture.capture(directory: directory, name: name + "-supplements-bottom")
            try await fixture.revealControl(id: "compose-edit-quote")
            try fixture.assertVisible(id: "compose-edit-quote")
            try fixture.capture(directory: directory, name: name + "-quotation-controls")
        }
        await fixture.model.requestClose()
        await fixture.mailbox.stop()
    }

    @MainActor final class Fixture {
        let app: AppModel
        let mailbox: MailboxModel
        let cache: MailCache
        let model: ComposeModel
        let window: NSWindow
        let controller: NSHostingController<AnyView>
        let defaults: UserDefaults
        let suite: String
        let outgoing: URL
        let savedFormattingPreference: Any?
        var root: NSView { controller.view }

        private init(app: AppModel, mailbox: MailboxModel, cache: MailCache, model: ComposeModel,
                     window: NSWindow, controller: NSHostingController<AnyView>, defaults: UserDefaults,
                     suite: String, outgoing: URL, savedFormattingPreference: Any?) {
            self.app = app; self.mailbox = mailbox; self.cache = cache; self.model = model
            self.window = window; self.controller = controller; self.defaults = defaults
            self.suite = suite; self.outgoing = outgoing
            self.savedFormattingPreference = savedFormattingPreference
        }

        static func make() async throws -> Fixture {
            let savedFormattingPreference = UserDefaults.standard.object(forKey: ComposePreferences.formatBarKey)
            let cache = try MailCache.inMemory()
            let account = AccountRecord(id: "compose-design", email: "compose@example.invalid",
                displayName: "Compose Audit", grantedScopes: [], addedAt: .now)
            let outgoing = FileManager.default.temporaryDirectory.appending(path: "TernComposeDesign-\(UUID().uuidString)")
            let mailbox = MailboxModel(account: account, cache: cache, gmail: AuditGmail(), outgoingDirectory: outgoing)
            await mailbox.start()
            let id = try #require(await mailbox.startCompose(.newMessage))
            let suite = "DesignCompose-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            let app = AppModel()
            let closer = ComposeWindowCloser()
            let content = ComposeView(localDraftID: id, mailbox: mailbox, isEdited: .constant(false),
                                      closer: closer, onMove: { _ in })
                .environment(app).defaultAppStorage(defaults)
            let controller = NSHostingController(rootView: AnyView(content))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 360))
            window.orderFront(nil)
            let deadline = ContinuousClock.now + .seconds(5)
            while closer.model?.phase != .open, ContinuousClock.now < deadline {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let model = try #require(closer.model)
            try #require(model.phase == .open)
            let fixture = Fixture(app: app, mailbox: mailbox, cache: cache, model: model, window: window,
                                  controller: controller, defaults: defaults, suite: suite, outgoing: outgoing,
                                  savedFormattingPreference: savedFormattingPreference)
            do {
                try await fixture.activate()
                try await fixture.waitUntil {
                    model.editor != nil && fixture.descendants(fixture.root).contains {
                        ($0 as? ComposeTextView)?.window === window
                    }
                }
                // Let the new draft's initial To focus request complete before
                // tests choose another native field.
                try await fixture.settle()
                return fixture
            } catch {
                fixture.dispose()
                await mailbox.stop()
                throw error
            }
        }

        func stress() async throws {
            model.content.to = Self.addresses("to")
            model.content.cc = Self.addresses("cc")
            model.content.bcc = Self.addresses("bcc")
            model.showsCc = true; model.showsBcc = true
            model.content.subject = "Field research review — synthetic draft"
            model.content.body = ComposeDocument(plainText: "Notes for the team.\nKeep writing here while reviewing recipients and files.")
            model.content.signatureAboveQuote = true
            model.content.signatureHTML = "<p>Alex Morgan<br>Field research</p>" + String(repeating: "<p>Research contact details</p>", count: 10)
            model.droppedFormatting = true
            #expect(await model.replaceQuote(with: String(repeating: "Earlier discussion and research notes.\n", count: 80)))
            model.attach((0..<12).map {
                .data(Data("Synthetic attachment \($0)".utf8), filename: "Research-notes-\($0).txt", mimeType: "text/plain")
            })
            try await waitUntil { self.model.attachments.count == 12 }
            if !model.showsFormatting { try await press(id: "compose-formatting-toggle") }
            try await waitUntil { self.model.showsFormatting }
            try await press(id: "compose-assistant-toggle")
            try await requireAssistantOpen()
            try await press(id: "compose-quote-toggle")
            try await waitUntil { self.element(id: "compose-edit-quote") != nil }
            try await press(label: "Signature")
            try await settle()
        }

        private func requireAssistantOpen() async throws {
            func state() -> (values: [String], inputs: [ComposePromptTextView]) {
                let values = actionTargets(id: "compose-assistant-toggle", label: nil).compactMap {
                    Self.attribute($0, "accessibilityValue", legacy: .value) as? String
                }
                let inputs = descendants(root).compactMap { $0 as? ComposePromptTextView }
                    .filter { $0.window === window }
                return (values, inputs)
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                let current = state()
                if current.values.contains("Open"), !current.inputs.isEmpty { return }
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let current = state()
            let message = "Assistant must open through the production toolbar. values=\(current.values) nativePromptCount=\(current.inputs.count) modelEditable=\(model.isEditable) phase=\(model.phase) key=\(window.isKeyWindow) active=\(NSApp.isActive)\n"
                + accessibilityNodes().filter {
                    Self.matches($0, id: "compose-assistant-toggle", label: nil)
                        || Self.matches($0, id: "compose-assistant-prompt", label: nil)
                        || Self.matches($0, id: "compose-assistant-bar", label: nil)
                }.map(Self.describe).joined(separator: "\n")
            Attachment.record(Array(message.utf8), named: "compose-assistant-open-diagnostic.txt")
            try #require(current.values.contains("Open") && !current.inputs.isEmpty, Comment(rawValue: message))
        }

        static func addresses(_ prefix: String) -> [EmailAddress] {
            (0..<45).map { .init(name: "Research participant \($0)", address: "\(prefix)-participant-\($0)@example.invalid") }
        }

        func dispose() {
            app.assistant.stop()
            window.close()
            defaults.removePersistentDomain(forName: suite)
            if let savedFormattingPreference {
                UserDefaults.standard.set(savedFormattingPreference, forKey: ComposePreferences.formatBarKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ComposePreferences.formatBarKey)
            }
            try? FileManager.default.removeItem(at: outgoing)
        }

        func bodyEditor() throws -> ComposeTextView {
            try #require(descendants(root).compactMap { $0 as? ComposeTextView }.first)
        }

        func activate() async throws {
            window.level = .floating
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            func isForeground() -> Bool {
                NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
            }
            let deadline = ContinuousClock.now + .seconds(5)
            var attempts = 1
            var nextAttempt = ContinuousClock.now + .milliseconds(250)
            while !isForeground(), ContinuousClock.now < deadline {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                if !isForeground(), attempts < 3, ContinuousClock.now >= nextAttempt {
                    NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                    window.makeKeyAndOrderFront(nil)
                    attempts += 1
                    nextAttempt = ContinuousClock.now + .milliseconds(250)
                }
            }
            let key = NSApp.keyWindow
            let keyDescription = key.map { "\(type(of: $0)) title=\($0.title) number=\($0.windowNumber) responder=\(String(describing: $0.firstResponder.map { type(of: $0) }))" } ?? "nil"
            let children = (window.childWindows ?? []).map { "\(type(of: $0)) title=\($0.title) key=\($0.isKeyWindow) visible=\($0.isVisible)" }
            let message = "Compose foreground prerequisite: active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.occlusionState.contains(.visible)) windowNumber=\(window.windowNumber) canBecomeKey=\(window.canBecomeKey) attempts=\(attempts) keyWindow=\(keyDescription) children=\(children) sheet=\(String(describing: window.attachedSheet)) modal=\(String(describing: NSApp.modalWindow))"
            if !isForeground() { Attachment.record(Array(message.utf8), named: "compose-window-activation.txt") }
            try #require(isForeground(), Comment(rawValue: message))
        }

        func focusRecipient(_ field: NSTokenField) async throws {
            try await activate()
            RecipientField.focus(field)
            try await settle()
            // Native completion/IME panels can transiently take key during focus.
            // Reactivate only this fixture window, without closing other windows.
            if !window.isKeyWindow { try await activate() }
            try #require(field.currentEditor() != nil, "The requested native recipient field must have an editor")
        }

        func focusBodyForTyping() async throws -> ComposeTextView {
            let editor = try bodyEditor()
            // The draft's initial focus task and native recipient commits must
            // finish before this explicit user focus change.
            try await settle()
            try await activate()
            try #require(window.makeFirstResponder(editor))
            func isReady() -> Bool {
                window.firstResponder === editor && model.isEditingMessage && !editor.hasMarkedText()
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while !isReady(), ContinuousClock.now < deadline {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            if !isReady() {
                let message = focusDiagnostic(editor)
                Attachment.record(Array(message.utf8), named: "compose-body-focus-prerequisite.txt")
                try #require(isReady(), Comment(rawValue: message))
            }
            // Callers insert text and assert the immediate draft without an await.
            try await settle()
            try #require(isReady(), Comment(rawValue: focusDiagnostic(editor)))
            return editor
        }

        private func focusDiagnostic(_ editor: ComposeTextView) -> String {
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return "Body focus prerequisite: active=\(NSApp.isActive) key=\(window.isKeyWindow) responder=\(responder) isBody=\(window.firstResponder === editor) modelFocus=\(model.isEditingMessage) marked=\(editor.hasMarkedText()) phase=\(model.phase)"
        }

        func recipient(_ label: String) throws -> NSTokenField {
            try #require(descendants(root).compactMap { $0 as? NSTokenField }.first { $0.accessibilityLabel() == label })
        }

        func assertWritingViewport() throws {
            root.layoutSubtreeIfNeeded()
            let editor = try bodyEditor()
            let scroll = try #require(editor.enclosingScrollView)
            #expect(scroll.contentView.bounds.height >= Tokens.Layout.editorMinHeight - 1)
            let visible = scroll.convert(scroll.bounds, to: root).intersection(root.bounds)
            #expect(visible.height >= Tokens.Layout.editorMinHeight - 1)
            #expect(root.bounds.height <= (window.contentView?.bounds.height ?? 0) + 1,
                    "Intrinsic header/supplement sizes must fit the native content area")
        }

        func assertCaretVisible(in field: NSTokenField) throws {
            try #require(NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible),
                "Recipient caret assertions require the activated native compose window")
            let editor = try #require(field.currentEditor() as? NSTextView)
            let screen = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            var caret = field.convert(window.convertFromScreen(screen), from: nil)
            // A native insertion point may have zero geometric width; its
            // painted hairline still has to lie inside the clipped viewport.
            caret.size.width = max(caret.width, Tokens.Border.hairline)
            if screen.height <= 0 || !field.visibleRect.intersects(caret) {
                let message = recipientGeometryDiagnostic(field, editor: editor)
                Attachment.record(Array(message.utf8), named: "compose-recipient-native-geometry.txt")
                print(message)
            }
            try #require(screen.height > 0 && !editor.visibleRect.isEmpty,
                "The actual native caret API and field editor must become visible after recipient reveal")
            #expect(field.visibleRect.intersection(caret).height >= caret.height - Tokens.Border.hairline,
                "The active recipient insertion point must be inside the bounded header; active=\(NSApp.isActive) key=\(window.isKeyWindow) screenCaret=\(screen)")
        }

        private func recipientGeometryDiagnostic(_ field: NSTokenField, editor: NSTextView) -> String {
            let layout = editor.layoutManager
            let container = editor.textContainer
            let fieldLabel = field.accessibilityLabel() ?? "nil"
            let editorType = String(describing: type(of: editor))
            let delegate = editor.delegate.map { String(describing: type(of: $0)) } ?? "nil"
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            return "Recipient native geometry: label=\(fieldLabel) fieldFrame=\(field.frame) fieldBounds=\(field.bounds) fieldVisible=\(field.visibleRect) editor=\(editorType) editorFrame=\(editor.frame) editorBounds=\(editor.bounds) editorVisible=\(editor.visibleRect) delegate=\(delegate) responder=\(responder) selected=\(editor.selectedRange()) marked=\(editor.markedRange()) textLength=\(editor.textStorage?.length ?? -1) layoutGlyphs=\(layout?.numberOfGlyphs ?? -1) containerSize=\(String(describing: container?.size)) containerOrigin=\(editor.textContainerOrigin) usedRect=\(String(describing: container.flatMap { layout?.usedRect(for: $0) })) extraLine=\(String(describing: layout?.extraLineFragmentRect)) headerClip=\(String(describing: field.enclosingScrollView?.contentView.bounds))"
        }

        func assertVisible(id: String) throws {
            let object = try #require(element(id: id, pressable: true), "Missing control: \(id)")
            let frame = Self.accessibilityFrame(object)
            let viewport = try supplementsScrollView()
            let visible = window.convertToScreen(viewport.convert(viewport.contentView.frame, to: nil))
            #expect(!frame.isEmpty && frame.intersects(visible),
                    "The scrolled supplement control must be visible: \(Self.describe(object))")
        }

        func supplementsScrollView() throws -> NSScrollView {
            let editor = try bodyEditor()
            let writingScroll = try #require(editor.enclosingScrollView)
            let writingFrame = writingScroll.convert(writingScroll.bounds, to: root)
            let candidates = descendants(root).compactMap { $0 as? NSScrollView }.filter {
                let frame = $0.convert($0.bounds, to: root)
                return $0 !== writingScroll && (root.isFlipped
                    ? frame.minY >= writingFrame.maxY - 1 : frame.maxY <= writingFrame.minY + 1)
            }
            return try #require(candidates.first { candidate in
                !candidates.contains { $0 !== candidate && candidate.isDescendant(of: $0) }
            }, "Production supplement scroll viewport is missing")
        }

        func scrollSupplementsToBottom() throws {
            let scroll = try supplementsScrollView()
            let document = try #require(scroll.documentView)
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y = document.isFlipped ? max(0, document.bounds.height - bounds.height) : 0
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }

        func press(id: String? = nil, label: String? = nil) async throws {
            try await activate()
            try await settle()
            let deadline = ContinuousClock.now + .seconds(5)
            while actionTargets(id: id, label: label).isEmpty, ContinuousClock.now < deadline {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            try await revealControl(id: id, label: label)
            let candidates = actionTargets(id: id, label: label)
            let diagnostics = "Requested id=\(id ?? "nil") label=\(label ?? "nil") key=\(window.isKeyWindow) active=\(NSApp.isActive)\n"
                + accessibilityNodes().filter { Self.matches($0, id: id, label: label) }.map(Self.describe).joined(separator: "\n")
                + "\nResolved actions:\n" + candidates.map(Self.describe).joined(separator: "\n")
            guard let target = candidates.first else {
                Issue.record(Comment(rawValue: "No accessible compose action. " + diagnostics))
                throw ControlFailure.missingAction
            }
            try #require(Self.performPress(target), Comment(rawValue: "Compose accessibility press failed. " + diagnostics))
        }

        func revealControl(id: String? = nil, label: String? = nil) async throws {
            guard label == "Signature" || id == "compose-quote-toggle" || id == "compose-edit-quote" else { return }
            let target = try #require(actionTargets(id: id, label: label).first,
                "Supplement action missing for id=\(id ?? "nil") label=\(label ?? "nil")")
            let scroll = try supplementsScrollView()
            let document = try #require(scroll.documentView)
            let rect = document.convert(window.convertFromScreen(Self.accessibilityFrame(target)), from: nil)
            document.scrollToVisible(rect.insetBy(dx: 0, dy: -Tokens.Space.s1))
            try await settle()
        }

        func element(id: String? = nil, label: String? = nil, pressable: Bool = false) -> NSObject? {
            if pressable { return actionTargets(id: id, label: label).first }
            return accessibilityNodes().first { Self.matches($0, id: id, label: label) }
        }

        private func actionTargets(id: String?, label: String?) -> [NSObject] {
            let matches = accessibilityNodes().filter { Self.matches($0, id: id, label: label) }
            var seen = Set<ObjectIdentifier>()
            let descendants = matches.flatMap { accessibilityNodes(roots: [$0]) }.filter {
                seen.insert(ObjectIdentifier($0)).inserted && Self.isActionTarget($0)
                    && (Self.attribute($0, "accessibilityEnabled", legacy: .enabled) as? Bool != false)
            }
            // Native toolbar viewers repeat their SwiftUI button's identifier and
            // advertise generic actions. Resolve the most specific semantic button
            // before considering advertised actions, so the wrapper cannot swallow it.
            let identities = Set(descendants.map(ObjectIdentifier.init))
            let leaves = descendants.filter { candidate in
                !accessibilityNodes(roots: [candidate]).dropFirst().contains {
                    identities.contains(ObjectIdentifier($0))
                }
            }
            return leaves.sorted { Self.actionScore($0) > Self.actionScore($1) }
        }

        private func accessibilityNodes(roots: [Any]? = nil) -> [NSObject] {
            var seen = Set<ObjectIdentifier>()
            var nodes: [NSObject] = []
            func visit(_ value: Any) {
                guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
                nodes.append(object)
                let children = Self.attribute(object, "accessibilityChildren", legacy: .children) as? [Any] ?? []
                for child in children + NSAccessibility.unignoredChildren(from: children) + ((object as? NSView)?.subviews ?? []) {
                    visit(child)
                }
            }
            let surfaces: [Any] = roots ?? [window, root] + (window.toolbar?.items.compactMap(\.view) ?? [])
            surfaces.forEach(visit)
            return nodes
        }

        private static func attribute(_ object: NSObject, _ key: String, legacy: NSAccessibility.Attribute) -> Any? {
            if object.responds(to: NSSelectorFromString(key)), let value = object.value(forKey: key) { return value }
            return legacyAttribute(object, legacy)
        }

        private static func legacyAttribute(_ object: NSObject, _ attribute: NSAccessibility.Attribute) -> Any? {
            guard object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
            return object.accessibilityAttributeValue(attribute)
        }

        private static func actions(_ object: NSObject) -> [NSAccessibility.Action] {
            guard object.responds(to: NSSelectorFromString("accessibilityActionNames")) else { return [] }
            return object.accessibilityActionNames()
        }

        private static func matches(_ object: NSObject, id: String?, label: String?) -> Bool {
            if let id { return attribute(object, "accessibilityIdentifier", legacy: .identifier) as? String == id }
            if let label {
                return attribute(object, "accessibilityLabel", legacy: .description) as? String == label
                    || legacyAttribute(object, .title) as? String == label
            }
            return false
        }

        private static func actionScore(_ object: NSObject) -> Int {
            let role = attribute(object, "accessibilityRole", legacy: .role) as? String ?? ""
            let names = actions(object)
            return (names.contains(.press) ? 2 : 0) + (["AXButton", "AXMenuButton", "AXCheckBox"].contains(role) ? 1 : 0)
        }

        private static func isActionTarget(_ object: NSObject) -> Bool {
            let role = attribute(object, "accessibilityRole", legacy: .role) as? String ?? ""
            return ["AXButton", "AXMenuButton", "AXCheckBox"].contains(role)
                && (object.responds(to: NSSelectorFromString("accessibilityPerformPress")) || actions(object).contains(.press))
        }

        private static func accessibilityFrame(_ object: NSObject) -> NSRect {
            if object.responds(to: NSSelectorFromString("accessibilityFrame")),
               let frame = object.value(forKey: "accessibilityFrame") as? NSValue { return frame.rectValue }
            guard let point = legacyAttribute(object, .position) as? NSValue,
                  let size = legacyAttribute(object, .size) as? NSValue else { return .zero }
            return NSRect(origin: point.pointValue, size: size.sizeValue)
        }

        private static func describe(_ object: NSObject) -> String {
            let identifier = attribute(object, "accessibilityIdentifier", legacy: .identifier) as? String ?? "nil"
            let role = attribute(object, "accessibilityRole", legacy: .role) as? String ?? "nil"
            let label = attribute(object, "accessibilityLabel", legacy: .description) as? String ?? "nil"
            let enabled = attribute(object, "accessibilityEnabled", legacy: .enabled) as? Bool
            return "\(type(of: object)) id=\(identifier) role=\(role) label=\(label) enabled=\(String(describing: enabled)) actions=\(actions(object)) frame=\(accessibilityFrame(object))"
        }

        private static func performPress(_ object: NSObject) -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if object.responds(to: selector), let implementation = object.method(for: selector) {
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                if unsafeBitCast(implementation, to: Press.self)(object, selector) { return true }
            }
            guard actions(object).contains(.press),
                  object.responds(to: NSSelectorFromString("accessibilityPerformAction:")) else { return false }
            object.accessibilityPerformAction(.press)
            return true
        }

        private enum ControlFailure: Error { case missingAction }

        func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < deadline {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(condition(), sourceLocation: sourceLocation)
        }

        func settle() async throws {
            for _ in 0..<5 {
                root.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
        }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }

        func capture(directory: String, name: String) throws {
            root.layoutSubtreeIfNeeded()
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            window.effectiveAppearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            Attachment.record(Array(data), named: "compose-" + name + ".png")
        }
    }
}
