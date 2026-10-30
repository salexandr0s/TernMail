import Foundation
import SwiftSoup

/// Turns draft HTML into a `ComposeDocument`, keeping only the formatting the
/// editor supports. It walks the markup itself rather than using AppKit's
/// importer, which runs WebKit and can fetch remote resources.
public enum HTMLImporter {
    public struct Result: Sendable, Equatable {
        public var document: ComposeDocument
        /// A `gmail_quote` block and everything after it, cleaned of active
        /// content, for the editor to keep unchanged.
        public var quotedTail: String?
        /// True when the HTML had formatting the editor can't keep, such as
        /// tables, images, fonts or colors.
        public var droppedFormatting: Bool
    }

    /// - Parameter detachingQuote: False keeps the quote as ordinary text.
    public static func importHTML(_ html: String, detachingQuote: Bool = true, preservingInlineImages: Bool = false) -> Result {
        guard let document = try? SwiftSoup.parse(html), let body = document.body() else {
            return Result(document: ComposeDocument(plainText: html), quotedTail: nil, droppedFormatting: true)
        }
        let quotedTail = detachingQuote ? (try? detachQuote(from: body)) ?? nil : nil
        var walker = Walker(preservingInlineImages: preservingInlineImages)
        walker.walk(body)
        walker.endBlock()
        return Result(document: ComposeDocument(blocks: walker.blocks), quotedTail: quotedTail, droppedFormatting: walker.dropped)
    }

    public static func inlineImageContentIDs(in html: String) -> Set<String> {
        guard let document = try? SwiftSoup.parse(html), let images = try? document.select("img[src]") else { return [] }
        return Set(images.array().compactMap { image in
            guard let source = try? image.attr("src"), source.lowercased().hasPrefix("cid:"),
                  let cid = String(source.dropFirst(4)).removingPercentEncoding,
                  InlineImageReference(contentID: cid).isValid else { return nil }
            return cid
        })
    }

    /// Removes the first `gmail_quote` element and its later siblings, and
    /// returns their cleaned markup.
    private static func detachQuote(from body: Element) throws -> String? {
        guard let quote = try body.select(".gmail_quote").first() else { return nil }
        var detached = [quote]
        var sibling = try quote.nextElementSibling()
        while let next = sibling {
            detached.append(next)
            sibling = try next.nextElementSibling()
        }
        let container = try SwiftSoup.parseBodyFragment("")
        guard let target = container.body() else { return nil }
        for element in detached {
            try element.remove()
            try target.appendChild(element)
        }
        _ = try HTMLSanitizer.clean(container, keepingRemoteLoads: true)
        container.outputSettings().prettyPrint(pretty: false)
        return try target.html()
    }

    private struct Style {
        var bold = false
        var italic = false
        var underline = false
        var link: URL?
    }

    private struct Walker {
        var preservingInlineImages = false
        var blocks: [ComposeDocument.Block] = []
        var dropped = false
        private var runs: [ComposeDocument.Run] = []
        private var style = Style()
        private var lists: [ComposeDocument.BlockKind] = []
        private var listItem: ComposeDocument.BlockKind?

        init(preservingInlineImages: Bool = false) {
            self.preservingInlineImages = preservingInlineImages
        }

        private static let ignored: Set<String> = [
            "script", "style", "head", "title", "template", "noscript", "iframe", "object", "embed", "svg", "math",
        ]
        private static let blockLevel: Set<String> = [
            "p", "div", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr", "hr", "section", "article",
        ]
        /// Elements whose look the editor can't reproduce. Their text stays.
        private static let unsupported: Set<String> = [
            "img", "table", "font", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "code", "s", "strike", "del",
            "sub", "sup", "hr", "blockquote", "video", "audio", "picture", "canvas",
        ]

        mutating func walk(_ node: Node) {
            if let text = node as? TextNode {
                append(text.getWholeText())
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagName().lowercased()
            if preservingInlineImages, tag == "img", let source = try? element.attr("src"), source.lowercased().hasPrefix("cid:") {
                let reference = InlineImageReference(contentID: String(source.dropFirst(4)).removingPercentEncoding ?? "", altText: (try? element.attr("alt")) ?? "")
                if reference.isValid { runs.append(.init("", image: reference)); return }
            }
            if Self.ignored.contains(tag) {
                if tag == "svg" || tag == "math" { dropped = true }
                return
            }
            if Self.unsupported.contains(tag) { dropped = true }

            let saved = style
            let savedListItem = listItem
            defer {
                style = saved
                listItem = savedListItem
            }
            applyStyle(of: element, tag: tag)

            switch tag {
            case "br":
                endBlock(keepingEmpty: true)
                return
            case "ul", "ol":
                endBlock()
                let level = lists.count
                lists.append(tag == "ul" ? .bulleted(level: level) : .numbered(level: level))
                walkChildren(of: element)
                lists.removeLast()
                endBlock()
                return
            case "li":
                endBlock()
                listItem = lists.last ?? .bulleted(level: 0)
                walkChildren(of: element)
                endBlock()
                return
            default:
                break
            }
            let isBlock = Self.blockLevel.contains(tag)
            if isBlock { endBlock() }
            walkChildren(of: element)
            if isBlock { endBlock() }
        }

        private mutating func walkChildren(of element: Element) {
            for child in element.getChildNodes() { walk(child) }
        }

        private mutating func applyStyle(of element: Element, tag: String) {
            switch tag {
            case "b", "strong": style.bold = true
            case "i", "em": style.italic = true
            case "u": style.underline = true
            case "a":
                if let href = try? element.attr("href"),
                   let url = ComposeDocument.safeLink(URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines))) {
                    style.link = url
                }
            default: break
            }
            if tag == "font", !(element.getAttributes()?.asList().isEmpty ?? true) { dropped = true }
            guard let css = try? element.attr("style"), !css.isEmpty else { return }
            for declaration in css.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let property = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespaces).lowercased()
                switch property {
                case "font-weight":
                    style.bold = value == "bold" || value == "bolder" || (Int(value) ?? 400) >= 600
                case "font-style":
                    style.italic = value.hasPrefix("italic") || value.hasPrefix("oblique")
                case "text-decoration", "text-decoration-line":
                    if value.contains("underline") { style.underline = true }
                    if value.contains("line-through") { dropped = true }
                case "color", "background", "background-color", "font-family", "font-size", "font":
                    dropped = true
                default:
                    break
                }
            }
        }

        /// Collapses whitespace as a browser would, and treats a no-break space as a space.
        private mutating func append(_ raw: String) {
            var text = ""
            var lastWasSpace = runs.last?.text.last.map { $0 == " " } ?? true
            for character in raw {
                if character == " " || character == "\t" || character == "\n" || character == "\r" || character == "\u{0C}" {
                    if !lastWasSpace { text.append(" ") }
                    lastWasSpace = true
                } else {
                    text.append(character == "\u{00A0}" ? " " : character)
                    lastWasSpace = false
                }
            }
            guard !text.isEmpty else { return }
            if var last = runs.last, last.image == nil, last.bold == style.bold, last.italic == style.italic,
               last.underline == style.underline, last.link == style.link {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                runs.append(ComposeDocument.Run(text, bold: style.bold, italic: style.italic, underline: style.underline, link: style.link))
            }
        }

        /// Ends the current line. A `br` keeps an empty line; block edges don't.
        mutating func endBlock(keepingEmpty: Bool = false) {
            if var last = runs.last, last.text.hasSuffix(" ") {
                last.text.removeLast()
                if last.text.isEmpty { runs.removeLast() } else { runs[runs.count - 1] = last }
            }
            guard keepingEmpty || !runs.isEmpty else { return }
            blocks.append(ComposeDocument.Block(listItem ?? .paragraph, runs: runs))
            runs = []
        }
    }
}
