import AppKit
import MessageContent
import SwiftUI
import Testing
@testable import Tern

@Suite @MainActor struct AttributedDocumentTests {
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
