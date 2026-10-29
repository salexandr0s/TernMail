import AppKit
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct AttributedDocumentTests {
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
