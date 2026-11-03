import Foundation

/// A message body as the compose editor holds it: paragraphs and list items
/// made of styled runs. The app maps it to and from `NSAttributedString`.
public struct ComposeDocument: Sendable, Equatable, Codable {
    public struct Run: Sendable, Equatable, Codable {
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        /// Only http, https and mailto links survive output.
        public var link: URL?
        public var image: InlineImageReference?

        public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, link: URL? = nil,
                    image: InlineImageReference? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.link = link
            self.image = image
        }
    }

    public enum BlockKind: Sendable, Equatable, Codable {
        case paragraph
        /// `level` 0 is the outermost list.
        case bulleted(level: Int)
        case numbered(level: Int)
    }

    public struct Block: Sendable, Equatable, Codable {
        public var kind: BlockKind
        public var runs: [Run]

        public init(_ kind: BlockKind = .paragraph, runs: [Run]) {
            self.kind = kind
            self.runs = runs
        }

        public var text: String { runs.map(\.text).joined() }
    }

    public var blocks: [Block]

    public init(blocks: [Block] = []) {
        self.blocks = blocks
    }

    /// One paragraph per line.
    public init(plainText: String) {
        let lines = plainText.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        blocks = lines.map { Block(runs: $0.isEmpty ? [] : [Run(String($0))]) }
    }

    public var isEmpty: Bool {
        blocks.allSatisfy { $0.text.allSatisfy(\.isWhitespace) && $0.runs.allSatisfy { $0.image == nil } }
    }

    /// Matches plainText().isEmpty without building the complete output for
    /// placeholder visibility. Newlines, list markers and images are content.
    public var isPlainTextEmpty: Bool {
        guard blocks.count <= 1 else { return false }
        guard let block = blocks.first else { return true }
        guard case .paragraph = block.kind else { return false }
        return block.runs.allSatisfy { run in
            guard run.image == nil, run.text.isEmpty else { return false }
            guard let link = Self.safeLink(run.link) else { return true }
            return link.scheme?.lowercased() == "mailto"
                && link.absoluteString.dropFirst("mailto:".count).isEmpty
        }
    }

    // MARK: Output

    /// Markup for the text/html part: a `div` per paragraph, as Gmail writes
    /// it, and nested `ul` or `ol` lists. Leading and repeated spaces and tabs
    /// keep their width.
    public func html() -> String {
        var output = ""
        var openLists: [String] = []
        for block in blocks {
            let (tag, level): (String?, Int) = switch block.kind {
            case .paragraph: (nil, -1)
            case .bulleted(let level): ("ul", max(0, level))
            case .numbered(let level): ("ol", max(0, level))
            }
            while openLists.count > level + 1 {
                output += "</\(openLists.removeLast())>"
            }
            guard let tag else {
                output += "<div>\(Self.html(block.runs))</div>"
                continue
            }
            if openLists.count == level + 1, openLists.last != tag {
                output += "</\(openLists.removeLast())>"
            }
            while openLists.count < level + 1 {
                output += "<\(tag)>"
                openLists.append(tag)
            }
            output += "<li>\(Self.html(block.runs))</li>"
        }
        while let tag = openLists.popLast() {
            output += "</\(tag)>"
        }
        return output
    }

    /// Text for the text/plain part. Lists are indented and marked, and a
    /// link whose text isn't its address is followed by the address.
    public func plainText() -> String {
        var lines: [String] = []
        var counters: [Int] = []
        for block in blocks {
            let text = block.runs.map { run in
                if let image = run.image { return image.altText.isEmpty ? "[Image]" : image.altText }
                guard let link = Self.safeLink(run.link) else { return run.text }
                let address = link.scheme?.lowercased() == "mailto" ? String(link.absoluteString.dropFirst("mailto:".count)) : link.absoluteString
                return run.text == address || run.text == link.absoluteString ? run.text : "\(run.text) <\(address)>"
            }.joined()
            switch block.kind {
            case .paragraph:
                counters = []
                lines.append(text)
            case .bulleted(let level):
                counters = Array(counters.prefix(level + 1))
                lines.append(String(repeating: "    ", count: level) + "- " + text)
            case .numbered(let level):
                counters = Array(counters.prefix(level + 1))
                while counters.count < level + 1 { counters.append(0) }
                counters[level] += 1
                lines.append(String(repeating: "    ", count: level) + "\(counters[level]). " + text)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func html(_ runs: [Run]) -> String {
        guard runs.contains(where: { !$0.text.isEmpty || $0.image != nil }) else { return "<br>" }
        var previous = Previous.lineStart
        return runs.map { run in
            if let image = run.image, image.isValid {
                // HTMLImporter drops a plain space after an image, as it does at the start of a line.
                previous = .lineStart
                return "<img src=\"cid:\(MessageDocument.escaped(image.contentID))\" alt=\"\(MessageDocument.escaped(image.altText))\">"
            }
            var text = markup(run.text, after: &previous)
            if run.underline { text = "<u>\(text)</u>" }
            if run.italic { text = "<i>\(text)</i>" }
            if run.bold { text = "<b>\(text)</b>" }
            if let link = safeLink(run.link) {
                text = "<a href=\"\(MessageDocument.escaped(link.absoluteString))\">\(text)</a>"
            }
            return text
        }.joined()
    }

    /// What the line so far ends with, which decides how a space after it is written.
    private enum Previous {
        /// Nothing yet, or a line break.
        case lineStart
        /// A visible character, or a tab, which its `pre` span keeps.
        case text
        case space
        case noBreakSpace
    }

    /// Escapes run text and writes its spacing so the HTML keeps what the
    /// editor shows. A line break becomes `br`, and tabs go in a
    /// `white-space:pre` span, which keeps their width. A space becomes
    /// `&nbsp;` where HTML would drop or collapse it: at the start of a line
    /// and after a plain space. Plain spaces stay between those, so long runs
    /// can still wrap. `HTMLImporter` drops a plain space that starts a run
    /// right after any space, so such a space is written as `&nbsp;` too.
    private static func markup(_ text: String, after previous: inout Previous) -> String {
        var output = ""
        var inTabs = false
        for (offset, character) in MessageDocument.escaped(text).enumerated() {
            if character == "\t" {
                if !inTabs { output += "<span style=\"white-space:pre\">" }
                inTabs = true
                output.append(character)
                previous = .text
                continue
            }
            if inTabs { output += "</span>" }
            inTabs = false
            switch character {
            case "\n", "\r\n":
                output += "<br>"
                previous = .lineStart
            case " ":
                let plain = previous == .text || (previous == .noBreakSpace && offset > 0)
                output += plain ? " " : "&nbsp;"
                previous = plain ? .space : .noBreakSpace
            case "\u{00A0}":
                output.append(character)
                previous = .noBreakSpace
            default:
                output.append(character)
                previous = .text
            }
        }
        if inTabs { output += "</span>" }
        return output
    }

    static func safeLink(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }
}
