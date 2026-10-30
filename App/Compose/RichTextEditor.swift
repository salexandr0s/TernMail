import AppKit
import MessageContent
import SwiftUI

/// The formatting at the selection, for the format bar and menus.
struct TextFormat: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var linkURL: URL?
    var link: Bool { linkURL != nil }
    var list: ListStyle?
}

enum ListStyle: Equatable {
    case bulleted, numbered
}

/// What the format bar and menus ask of the editor.
@MainActor
protocol RichTextEditing: AnyObject {
    func toggleBold()
    func toggleItalic()
    func toggleUnderline()
    func toggleList(_ style: ListStyle)
    /// Links the selection or the link at the cursor. At an unlinked cursor,
    /// inserts the address. Nil removes links while keeping the text.
    func setLink(_ url: URL?)
    /// Puts the cursor in the message, at its start.
    func focus()
}

/// The message body editor: an `NSTextView`, since SwiftUI's rich text
/// editing needs macOS 26. It edits a `ComposeDocument` and keeps only the
/// formatting the document can hold.
struct RichTextEditor: NSViewRepresentable {
    @Binding var document: ComposeDocument
    @Binding var format: TextFormat
    var isEditable: Bool
    /// Hands over the editor once it exists, so menus can send it commands.
    var onReady: (any RichTextEditing) -> Void
    /// Files, or an image without text, dropped or pasted into the message.
    var onAttach: ([Attachable]) -> Void
    /// Whether the cursor is in the message, which formatting applies to.
    var onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 keeps list markers in the text, which AppKit's list
        // editing (Return continues a list, Return on an empty item ends it) relies on.
        let textView = ComposeTextView(usingTextLayoutManager: false)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Tokens.Space.s4, height: Tokens.Space.s3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = AttributedDocument.baseAttributes
        textView.setAccessibilityLabel("Message")
        textView.onAttach = onAttach
        textView.onFocusChange = onFocusChange
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.load(document)
        onReady(context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView?.isEditable = isEditable
        if let textView = context.coordinator.textView as? ComposeTextView {
            textView.onAttach = onAttach
            textView.onFocusChange = onFocusChange
        }
        if document != context.coordinator.lastDocument {
            context.coordinator.load(document)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, RichTextEditing {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        /// The document the text view shows, so updates that come back from
        /// the binding don't reset the text and selection.
        private(set) var lastDocument = ComposeDocument()
        /// Replacing the text moves the selection, which mustn't update the
        /// format during the view update that loads it.
        private var isLoading = false

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func load(_ document: ComposeDocument) {
            guard let textView, let storage = textView.textStorage else { return }
            lastDocument = document
            isLoading = true
            storage.setAttributedString(AttributedDocument.string(from: document))
            textView.typingAttributes = AttributedDocument.baseAttributes
            isLoading = false
            textView.undoManager?.removeAllActions(withTarget: storage)
            // Loading happens while SwiftUI updates views, which mustn't change state.
            Task { @MainActor [weak self] in self?.updateFormat() }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            publish()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading else { return }
            updateFormat()
        }

        // MARK: NSTextStorageDelegate

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            willProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            // Pasted text brings fonts, sizes and colors the message can't keep.
            // Text storage delegates are called on the thread editing the
            // storage, which for a text view is the main thread, so the storage
            // never crosses threads here.
            nonisolated(unsafe) let storage = textStorage
            MainActor.assumeIsolated {
                AttributedDocument.normalize(storage, in: editedRange)
            }
        }

        // MARK: RichTextEditing

        func focus() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        func toggleBold() { toggle(.boldFontMask) }
        func toggleItalic() { toggle(.italicFontMask) }

        func toggleUnderline() {
            change { storage, range in
                let isOn = AttributedDocument.all(storage, in: range) { ($0[.underlineStyle] as? Int ?? 0) != 0 }
                if isOn {
                    storage.removeAttribute(.underlineStyle, range: range)
                } else {
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            } typing: { attributes in
                let isOn = (attributes[.underlineStyle] as? Int ?? 0) != 0
                attributes[.underlineStyle] = isOn ? nil : NSUnderlineStyle.single.rawValue
            }
        }

        func setLink(_ url: URL?) {
            guard let textView, let storage = textView.textStorage else { return }
            var range = textView.selectedRange()
            if range.length == 0, storage.length > 0 {
                let location = min(range.location, storage.length - 1)
                var linkedRange = NSRange()
                let link = storage.attribute(
                    .link, at: location, longestEffectiveRange: &linkedRange,
                    in: NSRange(location: 0, length: storage.length)
                )
                if link != nil, range.location < storage.length || textView.typingAttributes[.link] != nil {
                    range = linkedRange
                }
            }
            if range.length == 0 {
                guard let url else { return }
                var attributes = textView.typingAttributes
                attributes[.link] = url
                let text = NSAttributedString(string: url.absoluteString, attributes: attributes)
                guard textView.shouldChangeText(in: range, replacementString: text.string) else { return }
                storage.replaceCharacters(in: range, with: text)
                textView.didChangeText()
                textView.setSelectedRange(NSRange(location: range.location + text.length, length: 0))
            } else {
                guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
                storage.beginEditing()
                if let url {
                    storage.addAttribute(.link, value: url, range: range)
                } else {
                    storage.removeAttribute(.link, range: range)
                }
                storage.endEditing()
                textView.didChangeText()
                var attributes = textView.typingAttributes
                attributes[.link] = url
                textView.typingAttributes = attributes
            }
            updateFormat()
        }

        func toggleList(_ style: ListStyle) {
            guard let textView, let storage = textView.textStorage else { return }
            var document = AttributedDocument.document(from: storage)
            let selection = textView.selectedRange()
            let start = AttributedDocument.position(of: selection.location, in: storage)
            let end = AttributedDocument.position(of: NSMaxRange(selection), in: storage)
            let indexes = start.block...end.block
            let removing = indexes.allSatisfy { index in
                switch document.blocks[index].kind {
                case .bulleted: style == .bulleted
                case .numbered: style == .numbered
                case .paragraph: false
                }
            }
            for index in indexes {
                document.blocks[index].kind = switch (removing, style) {
                case (true, _): .paragraph
                case (false, .bulleted): .bulleted(level: 0)
                case (false, .numbered): .numbered(level: 0)
                }
            }
            let text = AttributedDocument.string(from: document)
            let whole = NSRange(location: 0, length: storage.length)
            guard textView.shouldChangeText(in: whole, replacementString: text.string) else { return }
            storage.replaceCharacters(in: whole, with: text)
            textView.didChangeText()
            let from = AttributedDocument.location(of: start, in: storage)
            let to = AttributedDocument.location(of: end, in: storage)
            textView.setSelectedRange(NSRange(location: from, length: max(0, to - from)))
            updateFormat()
        }

        // MARK: Private

        private func toggle(_ trait: NSFontTraitMask) {
            let manager = NSFontManager.shared
            change { storage, range in
                let isOn = AttributedDocument.all(storage, in: range) { attributes in
                    (attributes[.font] as? NSFont).map { manager.traits(of: $0).contains(trait) } ?? false
                }
                storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let font = value as? NSFont ?? AttributedDocument.baseFont
                    let changed = isOn ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
                    storage.addAttribute(.font, value: changed, range: subrange)
                }
            } typing: { attributes in
                let font = attributes[.font] as? NSFont ?? AttributedDocument.baseFont
                let isOn = manager.traits(of: font).contains(trait)
                attributes[.font] = isOn ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            }
        }

        /// Applies an attribute change to the selection as one undoable step,
        /// or to the typing attributes when nothing is selected.
        private func change(
            _ apply: (NSTextStorage, NSRange) -> Void,
            typing: (inout [NSAttributedString.Key: Any]) -> Void
        ) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            if range.length == 0 {
                var attributes = textView.typingAttributes
                typing(&attributes)
                textView.typingAttributes = attributes
            } else {
                guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
                storage.beginEditing()
                apply(storage, range)
                storage.endEditing()
                textView.didChangeText()
            }
            updateFormat()
        }

        private func publish() {
            guard let storage = textView?.textStorage else { return }
            let document = AttributedDocument.document(from: storage)
            lastDocument = document
            if parent.document != document { parent.document = document }
        }

        private func updateFormat() {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            let attributes: [NSAttributedString.Key: Any] = if range.length == 0 || range.location >= storage.length {
                textView.typingAttributes
            } else {
                storage.attributes(at: range.location, effectiveRange: nil)
            }
            let traits = (attributes[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let paragraph = range.location < storage.length
                ? storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : attributes[.paragraphStyle] as? NSParagraphStyle
            let link = range.location < storage.length
                ? storage.attribute(.link, at: range.location, effectiveRange: nil)
                : attributes[.link]
            let format = TextFormat(
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                linkURL: (link as? URL) ?? (link as? String).flatMap { URL(string: $0) },
                list: paragraph?.textLists.last.map { AttributedDocument.isNumbered($0) ? .numbered : .bulleted }
            )
            if parent.format != format { parent.format = format }
        }
    }
}

/// Reads only text from the pasteboard, and turns files and images into
/// attachments instead of inserting them.
private final class ComposeTextView: NSTextView {
    var onAttach: (([Attachable]) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { reportFocus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { reportFocus(false) }
        return resigned
    }

    /// Focus can move while SwiftUI updates views, which mustn't change state.
    private func reportFocus(_ isFocused: Bool) {
        Task { @MainActor [weak self] in self?.onFocusChange?(isFocused) }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.rtf, .string, .URL]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    override func paste(_ sender: Any?) {
        guard let items = Self.attachables(on: .general) else { return super.paste(sender) }
        onAttach?(items)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.attachables(on: sender.draggingPasteboard) == nil ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.attachables(on: sender.draggingPasteboard) == nil ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable, let items = Self.attachables(on: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        onAttach?(items)
        return true
    }

    /// Files on the pasteboard, or an image with no text beside it, as from a screenshot.
    private static func attachables(on pasteboard: NSPasteboard) -> [Attachable]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.map(Attachable.file)
        }
        guard pasteboard.string(forType: .string) == nil, pasteboard.data(forType: .rtf) == nil else { return nil }
        if let png = pasteboard.data(forType: .png) {
            return [.data(png, filename: "Pasted Image.png", mimeType: "image/png")]
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [.data(png, filename: "Pasted Image.png", mimeType: "image/png")]
        }
        return nil
    }
}

/// Maps a `ComposeDocument` to the text view's attributed string and back.
/// List items carry their marker as text (a tab, the marker, a tab), as AppKit's
/// own list editing does.
@MainActor
enum AttributedDocument {
    static var baseFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: NSParagraphStyle.default]
    }

    static func string(from document: ComposeDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // The lists open at each level, so consecutive items share one list
        // and its numbering, as AppKit expects.
        var open: [(list: NSTextList, count: Int)] = []
        for (index, block) in document.blocks.enumerated() {
            let paragraph = NSMutableAttributedString()
            var style = NSParagraphStyle.default
            if let (numbered, level) = listInfo(block.kind) {
                open = Array(open.prefix(level + 1))
                if open.count == level + 1, isNumbered(open[level].list) != numbered { open.removeLast() }
                while open.count < level + 1 {
                    open.append((NSTextList(markerFormat: markerFormat(numbered: numbered, level: open.count), options: 0), 0))
                }
                open[level].count += 1
                let marker = open[level].list.marker(forItemNumber: open[level].count)
                paragraph.append(NSAttributedString(string: "\t\(marker)\t", attributes: baseAttributes))
                style = listStyle(open.map(\.list), level: level)
            } else {
                open = []
            }
            for run in block.runs {
                paragraph.append(NSAttributedString(string: run.text, attributes: attributes(for: run)))
            }
            if index < document.blocks.count - 1 {
                paragraph.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            result.append(paragraph)
        }
        return result
    }

    static func document(from text: NSAttributedString) -> ComposeDocument {
        let string = text.string as NSString
        var blocks: [ComposeDocument.Block] = []
        var start = 0
        while true {
            let range = string.paragraphRange(for: NSRange(location: start, length: 0))
            let content = contentRange(of: range, in: string)
            blocks.append(block(text, content: content))
            if NSMaxRange(range) >= string.length {
                // Text ending in a line break has an empty paragraph after it.
                if NSMaxRange(range) > NSMaxRange(content) { blocks.append(ComposeDocument.Block(runs: [])) }
                break
            }
            start = NSMaxRange(range)
        }
        return ComposeDocument(blocks: blocks)
    }

    /// Lists pasted from other apps may use any marker, so anything that
    /// isn't a bullet counts as numbered.
    static func isNumbered(_ list: NSTextList) -> Bool {
        let bullets: [NSTextList.MarkerFormat] = [.disc, .circle, .square, .hyphen, .diamond, .box, .check]
        return !bullets.contains { list.markerFormat.rawValue.contains($0.rawValue) }
    }

    /// Keeps bold, italic, underline, links and list styles in `range`, on the
    /// standard font and text color.
    static func normalize(_ storage: NSTextStorage, in range: NSRange) {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        let manager = NSFontManager.shared
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var kept: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
            var font = baseFont
            if let original = attributes[.font] as? NSFont {
                let traits = manager.traits(of: original)
                if traits.contains(.boldFontMask) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            }
            kept[.font] = font
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 { kept[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if let link = linkURL(attributes[.link]) { kept[.link] = link }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty {
                kept[.paragraphStyle] = style
            } else {
                kept[.paragraphStyle] = NSParagraphStyle.default
            }
            storage.setAttributes(kept, range: subrange)
        }
    }

    /// Whether every character in `range` matches.
    static func all(_ storage: NSTextStorage, in range: NSRange, where matches: ([NSAttributedString.Key: Any]) -> Bool) -> Bool {
        var result = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if !matches(attributes) {
                result = false
                stop.pointee = true
            }
        }
        return result
    }

    /// A location as a block index and an offset into the block's text, which
    /// stays valid when list markers change.
    struct Position {
        var block: Int
        var offset: Int
    }

    static func position(of location: Int, in text: NSAttributedString) -> Position {
        let string = text.string as NSString
        var block = 0
        var start = 0
        while start < string.length {
            let range = string.paragraphRange(for: NSRange(location: start, length: 0))
            let content = contentRange(of: range, in: string)
            // The end of the text is in the last paragraph, unless that ends
            // with a line break and so has an empty paragraph after it.
            let holdsEnd = NSMaxRange(range) >= string.length && NSMaxRange(content) == NSMaxRange(range)
            if location < NSMaxRange(range) || holdsEnd {
                let textStart = content.location + markerLength(text, content: content)
                return Position(block: block, offset: max(0, min(location, NSMaxRange(content)) - textStart))
            }
            start = NSMaxRange(range)
            block += 1
        }
        return Position(block: block, offset: 0)
    }

    static func location(of position: Position, in text: NSAttributedString) -> Int {
        let string = text.string as NSString
        var block = 0
        var start = 0
        while start < string.length {
            let range = string.paragraphRange(for: NSRange(location: start, length: 0))
            let content = contentRange(of: range, in: string)
            if block == position.block {
                let textStart = content.location + markerLength(text, content: content)
                return min(textStart + position.offset, NSMaxRange(content))
            }
            start = NSMaxRange(range)
            block += 1
        }
        // The empty paragraph after a final line break, or past the end.
        return string.length
    }

    // MARK: Private

    private static func listInfo(_ kind: ComposeDocument.BlockKind) -> (numbered: Bool, level: Int)? {
        switch kind {
        case .paragraph: nil
        case .bulleted(let level): (false, max(0, level))
        case .numbered(let level): (true, max(0, level))
        }
    }

    /// Bullets change with depth, as they do in a browser, and numbers end in a period.
    private static func markerFormat(numbered: Bool, level: Int) -> NSTextList.MarkerFormat {
        if numbered { return NSTextList.MarkerFormat("\(NSTextList.MarkerFormat.decimal.rawValue).") }
        return [.disc, .circle, .square][min(level, 2)]
    }

    private static func listStyle(_ lists: [NSTextList], level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textLists = lists
        let indent = Tokens.Space.s6 * CGFloat(level)
        let textStart = indent + Tokens.Space.s8
        style.tabStops = [
            NSTextTab(textAlignment: .natural, location: indent + Tokens.Space.s2),
            NSTextTab(textAlignment: .natural, location: textStart),
        ]
        style.headIndent = textStart
        return style
    }

    private static func attributes(for run: ComposeDocument.Run) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        attributes.removeValue(forKey: .paragraphStyle)
        let manager = NSFontManager.shared
        var font = baseFont
        if run.bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if run.italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        attributes[.font] = font
        if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link { attributes[.link] = link }
        return attributes
    }

    private static func contentRange(of paragraph: NSRange, in string: NSString) -> NSRange {
        var end = NSMaxRange(paragraph)
        while end > paragraph.location {
            let character = string.character(at: end - 1)
            // \n, \r, line separator, paragraph separator
            guard character == 0x0A || character == 0x0D || character == 0x2028 || character == 0x2029 else { break }
            end -= 1
        }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }

    /// The length of a list item's leading "\t<marker>\t", or 0.
    private static func markerLength(_ text: NSAttributedString, content: NSRange) -> Int {
        guard content.length > 0,
              let style = text.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle,
              !style.textLists.isEmpty
        else { return 0 }
        let string = text.string as NSString
        guard string.character(at: content.location) == 0x09 else { return 0 }
        let rest = NSRange(location: content.location + 1, length: content.length - 1)
        let tab = string.range(of: "\t", range: rest)
        return tab.location == NSNotFound ? 0 : NSMaxRange(tab) - content.location
    }

    private static func block(_ text: NSAttributedString, content: NSRange) -> ComposeDocument.Block {
        var kind = ComposeDocument.BlockKind.paragraph
        if content.length > 0,
           let style = text.attribute(.paragraphStyle, at: content.location, effectiveRange: nil) as? NSParagraphStyle,
           let list = style.textLists.last {
            let level = style.textLists.count - 1
            kind = isNumbered(list) ? .numbered(level: level) : .bulleted(level: level)
        }
        let marker = markerLength(text, content: content)
        let body = NSRange(location: content.location + marker, length: content.length - marker)
        var runs: [ComposeDocument.Run] = []
        let manager = NSFontManager.shared
        let string = text.string as NSString
        text.enumerateAttributes(in: body) { attributes, range, _ in
            let traits = (attributes[.font] as? NSFont).map { manager.traits(of: $0) } ?? []
            let run = ComposeDocument.Run(
                string.substring(with: range),
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                link: linkURL(attributes[.link])
            )
            if var last = runs.last, last.bold == run.bold, last.italic == run.italic,
               last.underline == run.underline, last.link == run.link {
                last.text += run.text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }
        return ComposeDocument.Block(kind, runs: runs)
    }

    private static func linkURL(_ value: Any?) -> URL? {
        switch value {
        case let url as URL: url
        case let string as String: URL(string: string)
        default: nil
        }
    }
}
