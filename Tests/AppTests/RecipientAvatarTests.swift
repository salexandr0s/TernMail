import AppKit
import MessageContent
import Testing
@testable import Tern

@MainActor @Suite(.serialized) struct RecipientAvatarTests {
    @Test func avatarDisplaySpaceNeverEntersEditingOrCopiedAddresses() throws {
        let valid = EmailAddress(name: "Doe, Jane", address: "jane@company.invalid")
        let invalid = EmailAddress(address: "unfinished")
        let recipient = RecipientField(label: "To", addresses: .constant([valid, invalid]), requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let field = RecipientField.makeField()
        field.delegate = coordinator
        coordinator.field = field
        coordinator.configureAvatars()
        coordinator.show([valid, invalid])
        defer { coordinator.cancelRequests() }
        let objects = try #require(field.objectValue as? [RecipientField.Token])
        #expect(objects.map(\.address) == [valid, invalid])
        #expect(RecipientTokenField.avatarTokens(in: field.attributedStringValue).count == 1)
        #expect(coordinator.tokenField(field, editingStringForRepresentedObject: objects[0]) == #""Doe, Jane" <jane@company.invalid>"#)
        #expect(coordinator.tokenField(field, styleForRepresentedObject: objects[1]) == .none)
        let pasteboard = NSPasteboard(name: .init("tern.recipient-avatar." + UUID().uuidString))
        #expect(coordinator.tokenField(field, writeRepresentedObjects: objects, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == #""Doe, Jane" <jane@company.invalid>, unfinished"#)
        #expect(pasteboard.string(forType: .string)?.contains(RecipientTokenField.avatarPrefix) == false)
    }

    @Test func avatarRefreshAndProxyMeasurementLeaveActiveTextAndMarkedTextAlone() throws {
        var writes = 0
        let recipient = RecipientField(label: "Cc", addresses: .init(get: { [] }, set: { _ in writes += 1 }), requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let (field, editor, window) = try editingField(coordinator)
        defer { coordinator.cancelRequests(); window.close() }
        editor.insertText("new@examp", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        let before = editor.string
        let selection = editor.selectedRange()
        field.refreshAvatars()
        _ = coordinator.measure(width: 200)
        #expect(editor.string == before)
        #expect(editor.selectedRange() == selection)

        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("測試", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let count = writes
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.refreshAvatars()
        #expect(editor.hasMarkedText())
        #expect(editor.markedRange() == marked)
        #expect(writes == count)
        editor.unmarkText()
    }

    @Test func suggestionsAcceptThroughNativeCompletionAndKeepCanonicalTokenData() throws {
        let address = EmailAddress(name: "Alex Example", address: "alex@company.invalid")
        let recipient = RecipientField(label: "Bcc", addresses: .constant([]), requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let (field, editor, window) = try editingField(coordinator)
        let avatars = RecipientAvatarController()
        avatars.configure(field: field, accountID: nil, context: .empty, showsLogos: false)
        defer { avatars.stop(); coordinator.cancelRequests(); window.close() }
        editor.insertText("al", replacementRange: NSRange(location: NSNotFound, length: 0))
        let row = RecipientSuggestion(completion: address.displayString, title: address.name ?? "", subtitle: address.address, address: address)
        avatars.present([row], for: field, query: "al", isCurrent: { true }, selectFirst: false)
        #expect(avatars.handleCommand(#selector(NSResponder.moveDown(_:)), editor: editor))
        #expect(avatars.handleCommand(#selector(NSResponder.insertTab(_:)), editor: editor))
        let objects = try #require(field.objectValue as? [Any])
        let tokens = objects.compactMap { ($0 as? RecipientField.Token)?.address }
        #expect(tokens == [address])
    }

    @Test func nativeKeysAcceptSuggestionsAppendedAfterAnExistingToken() async throws {
        let original = EmailAddress(name: "Original Bank", address: "team@original.invalid")
        let first = EmailAddress(name: "First Bank", address: "team@first.invalid")
        let second = EmailAddress(name: "Second Bank", address: "team@second.invalid")
        var addresses = [original]
        let recipient = RecipientField(label: "To", addresses: .init(get: { addresses }, set: { addresses = $0 }),
                                       requestsFocus: .constant(false), isEditable: true) { query in
            query == "bank" ? [first, second] : []
        }
        let coordinator = recipient.makeCoordinator()
        let (field, editor, window) = try editingField(coordinator)
        coordinator.show([original])
        defer { coordinator.cancelRequests(); window.close() }
        try press("\u{f703}", keyCode: 124, modifiers: .command, in: editor, window: window)
        for (character, code) in [(" ", UInt16(49)), ("b", 11), ("a", 0), ("n", 45), ("k", 40)] {
            try press(character, keyCode: code, in: editor, window: window)
        }
        let hasSuggestions = { window.childWindows?.contains { $0.isVisible && $0.contentView is NSScrollView } == true }
        for _ in 0..<50 {
            if hasSuggestions() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(hasSuggestions())
        try press("\u{f701}", keyCode: 125, in: editor, window: window)
        try press("\t", keyCode: 48, in: editor, window: window)
        #expect(addresses == [original, second])
        try press("\t", keyCode: 48, in: editor, window: window)
        let objects = try #require(field.objectValue as? [Any])
        #expect(objects.compactMap { ($0 as? RecipientField.Token)?.address } == [original, second])
    }

    @Test func focusingAFieldWithRecipientsLetsTypingAddAnother() throws {
        let original = EmailAddress(name: "Original Bank", address: "team@original.invalid")
        let recipient = RecipientField(label: "To", addresses: .constant([original]), requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let field = RecipientField.makeField()
        field.frame = NSRect(x: 0, y: 0, width: 500, height: 60)
        field.delegate = coordinator
        coordinator.field = field
        coordinator.show([original])
        let window = NSWindow(contentRect: field.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        defer { coordinator.cancelRequests(); window.close() }
        // How the copy a sender change makes puts the cursor back in To.
        RecipientField.focus(field)
        let editor = try #require(field.currentEditor() as? NSTextView)
        try press("b", keyCode: 11, in: editor, window: window)
        // The token is still there, with the typing after it.
        #expect(editor.string == "\u{FFFC}b")
    }

    @Test func staleSuggestionSelectionAndInputCompositionCannotReplaceText() throws {
        let recipient = RecipientField(label: "To", addresses: .constant([]), requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let (field, editor, window) = try editingField(coordinator)
        let avatars = RecipientAvatarController()
        avatars.configure(field: field, accountID: nil, context: .empty, showsLogos: false)
        defer { avatars.stop(); coordinator.cancelRequests(); window.close() }
        editor.insertText("al", replacementRange: NSRange(location: NSNotFound, length: 0))
        let row = RecipientSuggestion(completion: "alex@company.invalid", title: "Alex", subtitle: "alex@company.invalid", address: .init(address: "alex@company.invalid"))
        var current = true
        avatars.present([row], for: field, query: "al", isCurrent: { current }, selectFirst: true)
        current = false
        #expect(!avatars.handleCommand(#selector(NSResponder.insertNewline(_:)), editor: editor))
        #expect(editor.string == "al")

        current = true
        avatars.present([row], for: field, query: "al", isCurrent: { current }, selectFirst: true)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!avatars.handleCommand(#selector(NSResponder.insertNewline(_:)), editor: editor))
        #expect(editor.string == "al")

        editor.setSelectedRange(NSRange(location: 2, length: 0))
        avatars.present([row], for: field, query: "al", isCurrent: { current }, selectFirst: true)
        editor.setMarkedText("測", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!avatars.handleCommand(#selector(NSResponder.insertNewline(_:)), editor: editor))
        #expect(editor.hasMarkedText())
        editor.unmarkText()
    }

    @Test func tokenMenuEditsAndRemovesOnlyTheChosenAddress() throws {
        let named = EmailAddress(name: "Doe, Jane", address: "jane@company.invalid")
        let plain = EmailAddress(address: "sam@company.invalid")
        let last = EmailAddress(address: "lee@company.invalid")
        var addresses = [named, plain, last]
        let recipient = RecipientField(label: "To", addresses: .init(get: { addresses }, set: { addresses = $0 }),
                                       requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let (field, editor, window) = try editingField(coordinator, showing: addresses)
        defer { coordinator.cancelRequests(); window.close() }
        func choose(_ title: String, for index: Int) throws {
            let tokens = try #require(field.objectValue as? [Any])
            let menu = try #require(coordinator.tokenField(field, menuForRepresentedObject: tokens[index]))
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.isEnabled)
            menu.performActionForItem(at: menu.index(of: item))
        }

        try choose("Remove", for: 1)
        #expect(addresses == [named, last])

        try choose("Edit", for: 0)
        let text = RecipientField.editingString(named)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == text)
        #expect(addresses == [named, last])
        // Leaving the field turns the text back into the same address.
        window.makeFirstResponder(nil)
        #expect(addresses == [named, last])
        let objects = try #require(field.objectValue as? [Any])
        #expect(objects.compactMap { ($0 as? RecipientField.Token)?.address } == [named, last])
    }

    @Test func typedSeparatorsEndRecipientsOnlyOutsideQuotedNames() throws {
        var addresses: [EmailAddress] = []
        let recipient = RecipientField(label: "To", addresses: .init(get: { addresses }, set: { addresses = $0 }),
                                       requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let (field, editor, window) = try editingField(coordinator)
        defer { coordinator.cancelRequests(); window.close() }
        // The second comma has no recipient to end, so it adds nothing.
        try type(#""Doe, Jane" <jane@company.invalid>,, sam@company.invalid; lee@company.invalid"#, in: editor, window: window)
        try press("\r", keyCode: 36, in: editor, window: window)
        let expected = [EmailAddress(name: "Doe, Jane", address: "jane@company.invalid"),
                        EmailAddress(address: "sam@company.invalid"), EmailAddress(address: "lee@company.invalid")]
        #expect(editor.string == String(repeating: "\u{FFFC}", count: 3))
        #expect(addresses == expected)
        let objects = try #require(field.objectValue as? [Any])
        #expect(objects.compactMap { ($0 as? RecipientField.Token)?.address } == expected)
    }

    @Test func pastedRecipientsKeepQuotedNamesAndSplitAtNewLines() throws {
        var addresses: [EmailAddress] = []
        let recipient = RecipientField(label: "To", addresses: .init(get: { addresses }, set: { addresses = $0 }),
                                       requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let (field, editor, window) = try editingField(coordinator)
        defer { coordinator.cancelRequests(); window.close() }
        let pasteboard = NSPasteboard(name: .init("tern.recipient-paste." + UUID().uuidString))
        func paste(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            #expect(editor.readSelection(from: pasteboard))
        }
        paste(#""Doe, Jane" <jane@example.com>, bob@example.com"#)
        let pasted = [EmailAddress(name: "Doe, Jane", address: "jane@example.com"), EmailAddress(address: "bob@example.com")]
        #expect(addresses == pasted)
        paste("carol@example.com\ndan@example.com")
        let lines = [EmailAddress(address: "carol@example.com"), EmailAddress(address: "dan@example.com")]
        #expect(addresses == pasted + lines)
        // Text that skipped the tokenizer still splits when editing ends.
        editor.insertText("erin@example.com, fay@example.com", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        let expected = pasted + lines + [EmailAddress(address: "erin@example.com"), EmailAddress(address: "fay@example.com")]
        #expect(addresses == expected)
        let objects = try #require(field.objectValue as? [Any])
        #expect(objects.count == expected.count)
        #expect(objects.compactMap { ($0 as? RecipientField.Token)?.address } == expected)
    }

    @Test func doubleClickingANamedTokenEditsItsWholeQuotedName() throws {
        let named = EmailAddress(name: "Doe, Jane", address: "jane@company.invalid")
        let plain = EmailAddress(address: "sam@company.invalid")
        var addresses = [named, plain]
        let recipient = RecipientField(label: "To", addresses: .init(get: { addresses }, set: { addresses = $0 }),
                                       requestsFocus: .constant(false), isEditable: true) { _ in [] }
        let coordinator = recipient.makeCoordinator()
        let (field, editor, window) = try editingField(coordinator, showing: addresses)
        defer { coordinator.cancelRequests(); window.close() }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        let attachment = try #require(editor.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        let cell = try #require(attachment.attachmentCell)
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        layout.ensureLayout(for: container)
        let frame = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        let point = editor.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        for click in 1...2 {
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: click, clickCount: click, pressure: 1))
            _ = cell.trackMouse(with: event, in: frame, of: editor, atCharacterIndex: 0, untilMouseUp: false)
        }
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == RecipientField.editingString(named))
        #expect(addresses == [named, plain])
        window.makeFirstResponder(nil)
        #expect(addresses == [named, plain])
        let objects = try #require(field.objectValue as? [Any])
        #expect(objects.compactMap { ($0 as? RecipientField.Token)?.address } == [named, plain])
    }

    /// A field in a window with the cursor in it. `addresses` are its tokens
    /// before editing starts, as when someone clicks into a filled field.
    private func editingField(_ coordinator: RecipientField.Coordinator,
                              showing addresses: [EmailAddress] = []) throws -> (RecipientTokenField, NSTextView, NSWindow) {
        let field = RecipientField.makeField()
        field.frame = NSRect(x: 0, y: 0, width: 500, height: 60)
        field.delegate = coordinator
        coordinator.field = field
        coordinator.configureAvatars()
        if !addresses.isEmpty { coordinator.show(addresses) }
        let window = NSWindow(contentRect: field.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        field.selectText(nil)
        return (field, try #require(field.currentEditor() as? NSTextView), window)
    }

    private func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in editor: NSTextView, window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                isARepeat: false, keyCode: keyCode))
        editor.keyDown(with: event)
    }

    /// Types printable text a key at a time. The key code doesn't matter for these characters.
    private func type(_ text: String, in editor: NSTextView, window: NSWindow) throws {
        for character in text { try press(String(character), keyCode: 0, in: editor, window: window) }
    }
}
