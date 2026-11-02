import AppKit

/// The formats a reply copies in: as it reads on screen, as the Markdown the
/// model wrote, or as plain text.
extension AssistantMarkdown {
    enum CopyFormat { case formatted, markdown, plainText }

    /// Replaces the general pasteboard's contents. `formatted` writes rich text
    /// with a plain-text fallback for apps that can't take styles.
    static func copy(_ markdown: String, as format: CopyFormat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch format {
        case .formatted: pasteboard.writeObjects([richText(markdown)])
        case .markdown: pasteboard.setString(markdown, forType: .string)
        case .plainText: pasteboard.setString(plainText(markdown), forType: .string)
        }
    }

    /// The reply without Markdown syntax. List markers, table cells and code stay.
    static func plainText(_ markdown: String) -> String {
        richText(markdown).string
    }

    /// The reply with the fonts it shows on screen and no colors, so it reads
    /// in light and dark documents alike. Display limits don't apply.
    static func richText(_ markdown: String) -> NSAttributedString {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let output = NSMutableAttributedString()
        var previous: Block?
        for block in parse(markdown, isBounded: false) {
            let text = richText(of: block, body: body)
            guard text.length > 0 else { continue }
            if let previous {
                let continuesList = block.listDepth > 0 && previous.listDepth > 0 && !block.isListContinuation
                output.append(NSAttributedString(string: continuesList ? "\n" : "\n\n", attributes: [.font: body]))
            }
            output.append(text)
            previous = block
        }
        return output
    }

    private static func richText(of block: Block, body: NSFont) -> NSAttributedString {
        let content: NSAttributedString
        switch block.kind {
        case .rule:
            return NSAttributedString()
        case .code, .diagram:
            var code = String(block.text.characters)
            // Foundation appends one terminal LF, including to unfinished fences.
            if code.last == "\n" { code.removeLast() }
            content = NSAttributedString(string: code, attributes: [.font: monospaced(body)])
        case .table:
            let output = NSMutableAttributedString()
            for (index, row) in block.rows.enumerated() {
                if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: body])) }
                for (column, cell) in row.cells.enumerated() {
                    if column > 0 { output.append(NSAttributedString(string: "\t", attributes: [.font: body])) }
                    output.append(inline(cell, font: row.isHeader ? body.adding(.bold) : body))
                }
            }
            content = output
        case .heading:
            let style: NSFont.TextStyle = block.headingLevel == 1 ? .title3 : .headline
            content = inline(block.text, font: NSFont.preferredFont(forTextStyle: style).adding(.bold))
        case .paragraph:
            content = inline(block.text, font: body)
        }
        let indent = String(repeating: "\t", count: max(block.listDepth - 1, 0))
        let marker = block.isTaskCompleted.map { $0 ? "☑" : "☐" } ?? block.marker
        let prefix = marker.map { "\(indent)\($0) " } ?? (block.isListContinuation ? indent + "\t" : "")
        let output = NSMutableAttributedString(string: prefix, attributes: [.font: body])
        output.append(content)
        if block.isTaskCompleted == true {
            output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: prefix.utf16.count, length: content.length))
        }
        if block.listDepth > 0 {
            let continuation = NSAttributedString(string: String(repeating: "\t", count: block.listDepth), attributes: [.font: body])
            let text = output.string as NSString
            for index in stride(from: text.length - 2, through: prefix.utf16.count, by: -1)
                where text.character(at: index) == 10 {
                output.insert(continuation, at: index + 1)
            }
        }
        return output
    }

    /// Strong and emphasized text, code spans and strikethrough keep their look.
    private static func inline(_ text: AttributedString, font: NSFont) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code) ? monospaced(font) : font
            if intent.contains(.stronglyEmphasized) { runFont = runFont.adding(.bold) }
            if intent.contains(.emphasized) { runFont = runFont.adding(.italic) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return output
    }

    private static func monospaced(_ font: NSFont) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
    }
}

private extension NSFont {
    func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
