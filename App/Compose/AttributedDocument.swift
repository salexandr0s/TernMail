import AppKit
import MessageContent

/// Maps a `ComposeDocument` to the text view's attributed string and back.
/// List items carry their marker as text (a tab, the marker, a tab), as AppKit's
/// own list editing does.
@MainActor
enum AttributedDocument {
    static var baseFont: NSFont { NSFont.preferredFont(forTextStyle: .body) }

    static func baseFont(_ choice: ComposeFont) -> NSFont {
        switch choice {
        case .sansSerif: baseFont
        case .serif: baseFont.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: baseFont.pointSize) } ?? baseFont
        case .fixedWidth: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        }
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor, .paragraphStyle: NSParagraphStyle.default]
    }

    static func baseAttributes(_ font: ComposeFont) -> [NSAttributedString.Key: Any] {
        [.font: baseFont(font), .foregroundColor: NSColor.textColor, .paragraphStyle: NSParagraphStyle.default]
    }

    static func string(from document: ComposeDocument, font: ComposeFont = .sansSerif, inlineImages: [String: Data] = [:]) -> NSAttributedString {
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
                paragraph.append(NSAttributedString(string: "\t\(marker)\t", attributes: baseAttributes(font)))
                style = listStyle(open.map(\.list), level: level)
            } else {
                open = []
            }
            for run in block.runs {
                if let image = run.image, image.isValid {
                    paragraph.append(NSAttributedString(attachment: ComposeImageAttachment(reference: image, data: inlineImages[image.contentID])))
                } else {
                    paragraph.append(NSAttributedString(string: run.text, attributes: attributes(for: run, font: font)))
                }
            }
            if index < document.blocks.count - 1 {
                paragraph.append(NSAttributedString(string: "\n", attributes: baseAttributes(font)))
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
    static func normalize(_ storage: NSTextStorage, in range: NSRange, font choice: ComposeFont = .sansSerif) {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        let manager = NSFontManager.shared
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var kept: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
            var font = baseFont(choice)
            if let original = attributes[.font] as? NSFont {
                let traits = manager.traits(of: original)
                if traits.contains(.boldFontMask) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            }
            kept[.font] = font
            if let image = attributes[.attachment] as? ComposeImageAttachment { kept[.attachment] = image }
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

    private static func attributes(for run: ComposeDocument.Run, font choice: ComposeFont) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes(choice)
        attributes.removeValue(forKey: .paragraphStyle)
        let manager = NSFontManager.shared
        var font = baseFont(choice)
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
            if let attachment = attributes[.attachment] as? ComposeImageAttachment {
                runs.append(ComposeDocument.Run("", image: attachment.reference))
                return
            }
            let traits = (attributes[.font] as? NSFont).map { manager.traits(of: $0) } ?? []
            let run = ComposeDocument.Run(
                string.substring(with: range),
                bold: traits.contains(.boldFontMask),
                italic: traits.contains(.italicFontMask),
                underline: (attributes[.underlineStyle] as? Int ?? 0) != 0,
                link: linkURL(attributes[.link])
            )
            if var last = runs.last, last.image == nil, last.bold == run.bold, last.italic == run.italic,
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
