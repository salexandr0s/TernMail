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
}

@MainActor
private final class LinkTestTextView: NSTextView {
    let testUndoManager = UndoManager()
    override var undoManager: UndoManager? { testUndoManager }
}
