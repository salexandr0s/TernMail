import AppKit
import MessageContent
import SwiftUI
import Testing
@testable import Tern

@Suite @MainActor struct AttributedDocumentTests {
    @Test func bodyFileDropsUseTheAttachmentRouteWithoutInsertingPasteboardText() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let url = FileManager.default.temporaryDirectory.appending(path: "compose-drop.pdf")
        #expect(pasteboard.writeObjects([url as NSURL]))
        pasteboard.setString(url.path, forType: .string)
        let textView = ComposeTextView(usingTextLayoutManager: false)
        textView.string = "Keep this message"
        textView.isEditable = true
        var droppedFiles: [ComposeDroppedFile] = []
        var fileDropCount = 0
        var legacyAttachCount = 0
        textView.onDropFiles = { fileDropCount += 1; droppedFiles = $0 }
        textView.onAttach = { _ in legacyAttachCount += 1 }

        #expect(textView.attachmentDragOperation(on: pasteboard) == .copy)
        #expect(fileDropCount == 0)
        #expect(textView.routeAttachmentDrop(from: pasteboard) == true)
        #expect(fileDropCount == 1 && droppedFiles.count == 1)
        #expect(legacyAttachCount == 0)
        #expect(textView.string == "Keep this message")

        textView.isEditable = false
        #expect(textView.attachmentDragOperation(on: pasteboard) == NSDragOperation(rawValue: 0))
        #expect(textView.routeAttachmentDrop(from: pasteboard) == false)
        #expect(fileDropCount == 1 && legacyAttachCount == 0)
        textView.isEditable = true
        textView.onDropFiles = nil
        #expect(textView.routeAttachmentDrop(from: pasteboard) == true)
        #expect(legacyAttachCount == 1 && fileDropCount == 1)
        #expect(textView.string == "Keep this message")
    }

    @Test func bodyTextAndWebURLDropsKeepTheNativeTextRoute() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let textView = ComposeTextView(usingTextLayoutManager: false)
        textView.isEditable = true
        textView.onDropFiles = { _ in Issue.record("A text drop was treated as a file") }
        textView.onAttach = { _ in Issue.record("A text drop was treated as an attachment") }
        pasteboard.setString("Words to move", forType: .string)
        #expect(textView.attachmentDragOperation(on: pasteboard) == nil)
        #expect(textView.routeAttachmentDrop(from: pasteboard) == nil)

        pasteboard.clearContents()
        let url = try #require(URL(string: "https://example.invalid/guide.pdf"))
        #expect(pasteboard.writeObjects([url as NSURL]))
        pasteboard.setString(url.absoluteString, forType: .string)
        #expect(textView.attachmentDragOperation(on: pasteboard) == nil)
        #expect(textView.routeAttachmentDrop(from: pasteboard) == nil)
    }

    @Test func imageOnlyBodyDropsBecomeFilesWhileTextWithAnImageStaysText() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(png, forType: .png)
        let textView = ComposeTextView(usingTextLayoutManager: false)
        textView.isEditable = true
        var fileCount = 0
        textView.onDropFiles = { fileCount += $0.count }
        textView.onAttach = { _ in Issue.record("A dropped image used the inline paste route") }
        #expect(textView.routeAttachmentDrop(from: pasteboard) == true)
        #expect(fileCount == 1)

        pasteboard.setString("Selected text with an image", forType: .string)
        #expect(textView.attachmentDragOperation(on: pasteboard) == nil)
        #expect(textView.routeAttachmentDrop(from: pasteboard) == nil)
        #expect(fileCount == 1)

        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setString("<p>Rich text with an image</p>", forType: .html)
        #expect(textView.attachmentDragOperation(on: pasteboard) == nil)
        #expect(textView.routeAttachmentDrop(from: pasteboard) == nil)
        #expect(fileCount == 1)
    }

    @Test func returningFromAnotherFieldPreservesTheMessageSelection() throws {
        let editor = RichTextEditor(
            document: .constant(ComposeDocument()), format: .constant(TextFormat()),
            isEditable: true, onReady: { _ in }, onAttach: { _ in }, onFocusChange: { _ in }
        )
        let coordinator = editor.makeCoordinator()
        let textView = ComposeTextView(usingTextLayoutManager: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 400, height: 160))
        scroll.documentView = textView
        textView.frame = scroll.contentView.bounds
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.load(ComposeDocument(plainText: "First paragraph.\nSecond paragraph with a meeting time."))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        content.addSubview(scroll)
        let assistantField = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 32))
        content.addSubview(assistantField)

        for selection in [NSRange(location: 22, length: 0), NSRange(location: 18, length: 6)] {
            #expect(window.makeFirstResponder(textView))
            textView.setSelectedRange(selection)
            #expect(window.makeFirstResponder(assistantField))
            #expect(window.firstResponder !== textView)

            coordinator.resumeEditing()

            #expect(window.firstResponder === textView)
            #expect(textView.selectedRange() == selection)
        }

        // A draft replacement can shorten the body while the assistant has focus.
        #expect(window.makeFirstResponder(assistantField))
        coordinator.load(ComposeDocument(plainText: "Short"))
        coordinator.resumeEditing()
        #expect(window.firstResponder === textView)
        #expect(NSMaxRange(textView.selectedRange()) <= (textView.string as NSString).length)

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.focus()
        #expect(textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func editingALinkAtTheCursorPreservesTextAndCanBeUndone() throws {
        let original = try #require(URL(string: "https://example.com/guide"))
        let updated = try #require(URL(string: "https://example.com/revised"))
        var format = TextFormat()
        let editor = RichTextEditor(
            document: .constant(ComposeDocument()),
            format: Binding(get: { format }, set: { format = $0 }),
            isEditable: true, onReady: { _ in }, onAttach: { _ in }, onFocusChange: { _ in }
        )
        let coordinator = editor.makeCoordinator()
        let textView = LinkTestTextView(usingTextLayoutManager: false)
        textView.allowsUndo = true
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.load(ComposeDocument(blocks: [.init(runs: [
            .init("Read "), .init("guide", link: original), .init(".")
        ])]))
        let storage = try #require(textView.textStorage)
        let undo = textView.testUndoManager
        undo.groupsByEvent = false
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        #expect(format.linkURL == original)

        undo.beginUndoGrouping()
        coordinator.setLink(updated)
        undo.endUndoGrouping()
        #expect(textView.string == "Read guide.")
        #expect(storage.attribute(.link, at: 5, effectiveRange: nil) as? URL == updated)
        #expect(storage.attribute(.link, at: 9, effectiveRange: nil) as? URL == updated)
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
        #expect(undo.canUndo)
        undo.undo()
        #expect(storage.attribute(.link, at: 7, effectiveRange: nil) as? URL == original)

        undo.beginUndoGrouping()
        coordinator.setLink(nil)
        undo.endUndoGrouping()
        #expect(textView.string == "Read guide.")
        #expect(storage.attribute(.link, at: 5, effectiveRange: nil) == nil)
        #expect(storage.attribute(.link, at: 9, effectiveRange: nil) == nil)

        // An explicit selection changes only that selection.
        textView.setSelectedRange(NSRange(location: 5, length: 2))
        undo.beginUndoGrouping()
        coordinator.setLink(updated)
        undo.endUndoGrouping()
        #expect(storage.attribute(.link, at: 5, effectiveRange: nil) as? URL == updated)
        #expect(storage.attribute(.link, at: 7, effectiveRange: nil) == nil)

        // A cursor in plain text still inserts a new linked address.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        undo.beginUndoGrouping()
        coordinator.setLink(original)
        undo.endUndoGrouping()
        #expect(textView.string == original.absoluteString + "Read guide.")
        #expect(storage.attribute(.link, at: 0, effectiveRange: nil) as? URL == original)
    }

    /// What the editor shows must come back as the same document, or a sent
    /// message loses formatting or carries list markers as text.
    @Test func formattingAndListsSurviveTheEditor() throws {
        let link = try #require(URL(string: "https://example.com/plan"))
        let document = ComposeDocument(blocks: [
            .init(runs: [.init("Plain, "), .init("bold", bold: true), .init(" and "), .init("both", bold: true, italic: true)]),
            .init(runs: []),
            .init(.bulleted(level: 0), runs: [.init("First "), .init("link", underline: true, link: link)]),
            .init(.bulleted(level: 1), runs: [.init("Nested")]),
            .init(.bulleted(level: 0), runs: []),
            .init(.numbered(level: 0), runs: [.init("One")]),
            .init(.numbered(level: 0), runs: [.init("Two")]),
            .init(runs: [.init("After the list")]),
            .init(runs: []),
        ])
        let text = AttributedDocument.string(from: document)
        #expect(AttributedDocument.document(from: text) == document)
        // Numbering continues within a list.
        #expect(text.string.contains("\t2.\tTwo"))
    }

    /// A list started on the empty line after a final line break goes on
    /// that line, not the one above.
    @Test func theEndOfTextEndingInALineBreakIsTheEmptyLastBlock() {
        let text = NSAttributedString(string: "Shopping:\n")
        let end = AttributedDocument.position(of: text.length, in: text)
        #expect(end.block == 1 && end.offset == 0)
        #expect(AttributedDocument.location(of: end, in: text) == text.length)
        #expect(AttributedDocument.position(of: 3, in: text).block == 0)
        let unbroken = NSAttributedString(string: "Shopping:")
        #expect(AttributedDocument.position(of: unbroken.length, in: unbroken).block == 0)
    }

    @Test func pasteKeepsOnlyFormattingTheMessageCanHold() throws {
        let storage = NSTextStorage(string: "Pasted text", attributes: [
            .font: try #require(NSFont(name: "Times New Roman Bold", size: 30)),
            .foregroundColor: NSColor.systemRed,
            .backgroundColor: NSColor.yellow,
        ])
        AttributedDocument.normalize(storage, in: NSRange(location: 0, length: storage.length))
        let attributes = storage.attributes(at: 0, effectiveRange: nil)
        let font = try #require(attributes[.font] as? NSFont)
        #expect(font.pointSize == AttributedDocument.baseFont.pointSize)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(attributes[.foregroundColor] as? NSColor == NSColor.textColor)
        #expect(attributes[.backgroundColor] == nil)
        #expect(AttributedDocument.document(from: storage).blocks == [.init(runs: [.init("Pasted text", bold: true)])])
    }

    @Test func incrementalConversionMatchesFullConversionThroughParagraphAndFormattingEdits() throws {
        let link = try #require(URL(string: "https://example.com/plan"))
        let image = InlineImageReference(contentID: "draft-image", altText: "Sketch")
        let original = ComposeDocument(blocks: [
            .init(runs: [.init("Start 😀 cafe\u{301} "), .init("bold", bold: true)]),
            .init(.bulleted(level: 0), runs: [.init("First"), .init(" link", link: link)]),
            .init(.bulleted(level: 1), runs: [.init("Nested", italic: true)]),
            .init(.numbered(level: 0), runs: [.init("Numbered", underline: true)]),
            .init(runs: [.init("", image: image), .init(" image caption")]),
            .init(runs: [.init("Last")]), .init(runs: []),
        ])
        let text = NSMutableAttributedString(attributedString: AttributedDocument.string(from: original))
        var projection = AttributedDocumentProjection()
        projection.reset(from: text)
        #expect(projection.document == original)

        func replace(_ range: NSRange, with value: NSAttributedString) {
            text.replaceCharacters(in: range, with: value)
            projection.update(from: text, editedRange: NSRange(location: range.location, length: value.length),
                              changeInLength: value.length - range.length)
            #expect(projection.document == AttributedDocument.document(from: text))
        }
        func replace(_ range: NSRange, with value: String) {
            replace(range, with: NSAttributedString(string: value, attributes: AttributedDocument.baseAttributes))
        }

        replace((text.string as NSString).range(of: "😀"), with: "🧑🏽‍💻\nSplit")
        replace((text.string as NSString).range(of: "\nSplit"), with: " merged")
        let pasted = AttributedDocument.string(from: ComposeDocument(blocks: [
            .init(.numbered(level: 0), runs: [.init("Pasted", bold: true, italic: true, link: link)]),
            .init(runs: [.init("", image: image)]),
        ]))
        replace((text.string as NSString).range(of: "Nested"), with: pasted)
        let formatted = (text.string as NSString).range(of: "caption")
        text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: formatted)
        let formattingChanged = projection.update(from: text, editedRange: formatted, changeInLength: 0)
        #expect(formattingChanged)
        #expect(projection.document == AttributedDocument.document(from: text))
        // Attributes the model does not retain must not produce a body change.
        text.addAttribute(.backgroundColor, value: NSColor.yellow, range: formatted)
        let backgroundChanged = projection.update(from: text, editedRange: formatted, changeInLength: 0)
        #expect(!backgroundChanged)
        replace(NSRange(location: text.length - 1, length: 1), with: "")
        replace(NSRange(location: text.length, length: 0), with: "\n\n")
        replace(NSRange(location: 0, length: text.length), with: "")
        replace(NSRange(location: 0, length: 0), with: "Replaced\n😀\n")
        replace(NSRange(location: 0, length: text.length), with: "one\ntwo\n")
        replace(NSRange(location: 0, length: 1), with: "O")

        // NSString's paragraph rules include CRLF and Unicode separators.
        replace(NSRange(location: 0, length: text.length), with: "one\r\ntwo\u{2028}three\u{2029}four\rfive\n")
        replace((text.string as NSString).range(of: "\r\n"), with: "\r")
        replace((text.string as NSString).range(of: "\r"), with: "\r\n")
        replace((text.string as NSString).range(of: "\u{2029}"), with: "")
    }

    @Test func coordinatorPublishesLatestBodySynchronouslyThroughNativeEditingAndReplacement() throws {
        var document = ComposeDocument(plainText: "First 😀\nSecond paragraph\nLast")
        var publications = 0
        let editor = RichTextEditor(
            document: Binding(get: { document }, set: { document = $0; publications += 1 }),
            format: .constant(TextFormat()), isEditable: true,
            onReady: { _ in }, onAttach: { _ in }, onFocusChange: { _ in }
        )
        let coordinator = editor.makeCoordinator()
        let textView = LinkTestTextView(usingTextLayoutManager: false)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.load(document)
        #expect(publications == 0)
        let storage = try #require(textView.textStorage)
        let undo = textView.testUndoManager
        undo.groupsByEvent = false

        // Send, save and close handlers read this same binding before the run
        // loop gets another turn. Every native change must already be present.
        func actionSnapshot() -> ComposeDocument { document }
        func expectCurrent() {
            #expect(actionSnapshot() == AttributedDocument.document(from: storage))
            #expect(coordinator.lastDocument == document)
        }
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        undo.beginUndoGrouping()
        textView.insertText(" typed", replacementRange: textView.selectedRange())
        undo.endUndoGrouping()
        expectCurrent()
        #expect(document.plainText().contains("typed"))
        let selection = textView.selectedRange()
        #expect(selection.length == 0)
        undo.undo()
        expectCurrent()
        #expect(!document.plainText().contains("typed"))
        undo.redo()
        expectCurrent()
        #expect(document.plainText().contains("typed"))

        undo.beginUndoGrouping()
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: textView.selectedRange())
        expectCurrent()
        #expect(textView.hasMarkedText())
        #expect(textView.selectedRange().location == storage.length)
        textView.insertText("日本", replacementRange: textView.markedRange())
        expectCurrent()
        #expect(document.plainText().hasSuffix("日本"))

        // Several character and attribute edits can be coalesced into one
        // processed range, or finish before a single text-change notification.
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "New\nlead")
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\nTail")
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                             range: NSRange(location: 0, length: 3))
        storage.endEditing()
        expectCurrent()
        textView.didChangeText()
        expectCurrent()
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        coordinator.toggleBold()
        expectCurrent()
        coordinator.toggleList(.numbered)
        expectCurrent()
        #expect(document.blocks.first?.kind == .numbered(level: 0))
        #expect(document.blocks.first?.runs.first?.bold == true)

        document = ComposeDocument(plainText: "External replacement")
        let beforeLoad = publications
        coordinator.load(document)
        #expect(publications == beforeLoad)
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        textView.insertText(" latest", replacementRange: textView.selectedRange())
        expectCurrent()
        #expect(document.plainText() == "External replacement latest")
        #expect(textView.selectedRange().location == storage.length)
        undo.endUndoGrouping()

        // A loaded empty document has no blocks, while text conversion has an
        // empty paragraph. Its next native notification still canonicalizes it.
        document = ComposeDocument()
        coordinator.load(document)
        let before = publications
        textView.didChangeText()
        expectCurrent()
        #expect(publications == before + 1)
        #expect(document.blocks == [.init(runs: [])])
        textView.didChangeText()
        #expect(publications == before + 1)

        let markdownKey = ComposePreferences.markdownKey
        let previousMarkdown = UserDefaults.standard.object(forKey: markdownKey)
        UserDefaults.standard.set(true, forKey: markdownKey)
        defer {
            if let previousMarkdown { UserDefaults.standard.set(previousMarkdown, forKey: markdownKey) }
            else { UserDefaults.standard.removeObject(forKey: markdownKey) }
        }
        let markdownView = ComposeTextView(usingTextLayoutManager: false)
        markdownView.delegate = coordinator
        markdownView.textStorage?.delegate = coordinator
        coordinator.textView = markdownView
        document = ComposeDocument()
        coordinator.load(document)
        for character in "**bold**" {
            markdownView.insertText(String(character), replacementRange: markdownView.selectedRange())
            #expect(document == AttributedDocument.document(from: markdownView.attributedString()))
        }
        #expect(document == ComposeDocument(blocks: [.init(runs: [.init("bold", bold: true)])]))
        #expect(markdownView.selectedRange() == NSRange(location: 4, length: 0))
    }
}

@MainActor
private final class LinkTestTextView: NSTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}
