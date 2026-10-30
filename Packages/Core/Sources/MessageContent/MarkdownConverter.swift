import Foundation

/// The compose subset: paragraphs, nested lists, emphasis and safe links.
public enum MarkdownConverter {
    public static func document(from text: String) -> ComposeDocument {
        guard text.utf8.count <= 1_048_576 else { return ComposeDocument(plainText: text) }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        return ComposeDocument(blocks: lines.map { line in
            let original = String(line)
            let trimmed = original.drop(while: { $0 == " " || $0 == "\t" })
            let indent = original.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let level = min(8, indent / 4)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                return ComposeDocument.Block(.bulleted(level: level), runs: runs(String(trimmed.dropFirst(2))))
            }
            let digits = trimmed.prefix(while: \.isNumber)
            if !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") {
                return ComposeDocument.Block(.numbered(level: level), runs: runs(String(trimmed.dropFirst(digits.count + 2))))
            }
            return ComposeDocument.Block(runs: runs(original))
        })
    }

    private static func runs(_ text: String, depth: Int = 0, bold: Bool = false, italic: Bool = false) -> [ComposeDocument.Run] {
        guard depth < 8 else { return [.init(text, bold: bold, italic: italic)] }
        var output: [ComposeDocument.Run] = []
        var plain = ""
        var cursor = text.startIndex
        func flush() {
            if !plain.isEmpty { output.append(.init(plain, bold: bold, italic: italic)); plain = "" }
        }
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            if text[cursor] == "\\", next < text.endIndex {
                plain.append(text[next]); cursor = text.index(after: next); continue
            }
            if text[cursor] == "[", let labelEnd = text[next...].firstIndex(of: "]") {
                let opening = text.index(after: labelEnd)
                if opening < text.endIndex, text[opening] == "(",
                   let end = text[text.index(after: opening)...].firstIndex(of: ")"),
                   let url = URL(string: String(text[text.index(after: opening)..<end])), ComposeDocument.safeLink(url) != nil {
                    flush()
                    var label = runs(String(text[next..<labelEnd]), depth: depth + 1, bold: bold, italic: italic)
                    for index in label.indices { label[index].link = url }
                    output += label; cursor = text.index(after: end); continue
                }
            }
            if text[cursor] == "*" || text[cursor] == "_" {
                let marker = next < text.endIndex && text[next] == text[cursor] ? String(repeating: text[cursor], count: 2) : String(text[cursor])
                let start = text.index(cursor, offsetBy: marker.count)
                if let close = text.range(of: marker, range: start..<text.endIndex), close.lowerBound > start,
                   !text[start].isWhitespace, !text[text.index(before: close.lowerBound)].isWhitespace {
                    flush()
                    output += runs(String(text[start..<close.lowerBound]), depth: depth + 1,
                                   bold: bold || marker.count == 2, italic: italic || marker.count == 1)
                    cursor = close.upperBound; continue
                }
                plain += marker
                cursor = start
                continue
            }
            plain.append(text[cursor]); cursor = next
        }
        flush()
        return output
    }
}
