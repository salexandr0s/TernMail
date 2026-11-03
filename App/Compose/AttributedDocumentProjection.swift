import AppKit
import MessageContent

/// Keeps paragraph conversion current after each processed text-storage edit.
/// Ranges use NSString's UTF-16 coordinates, including paragraph separators.
@MainActor
struct AttributedDocumentProjection {
    private(set) var document = ComposeDocument()
    private var ranges: [NSRange] = []
    private var length = 0

    mutating func reset(from text: NSAttributedString) {
        let paragraphs = AttributedDocument.paragraphs(from: text, in: NSRange(location: 0, length: text.length))
        document = ComposeDocument(blocks: paragraphs.map(\.block))
        ranges = paragraphs.map(\.range)
        length = text.length
    }

    /// NSTextStorage reports the range after editing and the net length change.
    /// Updating for every callback also handles several edits before didChangeText.
    @discardableResult
    mutating func update(from text: NSAttributedString, editedRange: NSRange, changeInLength delta: Int) -> Bool {
        let replacedLength = editedRange.length - delta
        guard !ranges.isEmpty, text.length == length + delta,
              editedRange.location != NSNotFound, editedRange.location <= length,
              editedRange.length >= 0, replacedLength >= 0,
              NSMaxRange(editedRange) <= text.length,
              editedRange.location + replacedLength <= length else {
            return rebuild(from: text)
        }

        // Include both neighboring paragraphs. Insertion or deletion beside a
        // separator can split or merge paragraphs, including the two halves of CRLF.
        let first = max(0, paragraph(at: editedRange.location) - 1)
        var last = min(ranges.count - 1, paragraph(at: editedRange.location + replacedLength) + 1)
        // The final line break and its synthetic empty paragraph share an end.
        // A conversion reaching EOF emits that empty paragraph itself.
        if NSMaxRange(ranges[last]) == length { last = ranges.count - 1 }
        let indexes = first..<(last + 1)
        let start = ranges[first].location
        let end = NSMaxRange(ranges[last]) + delta
        let string = text.string as NSString
        guard end >= start, end <= text.length,
              string.paragraphRange(for: NSRange(location: start, length: 0)).location == start,
              end == text.length || string.paragraphRange(for: NSRange(location: end, length: 0)).location == end else {
            return rebuild(from: text)
        }

        let paragraphs = AttributedDocument.paragraphs(from: text, in: NSRange(location: start, length: end - start))
        let blocks = paragraphs.map(\.block)
        let changed = !document.blocks[indexes].elementsEqual(blocks)
        if changed { document.blocks.replaceSubrange(indexes, with: blocks) }
        ranges.replaceSubrange(indexes, with: paragraphs.map(\.range))
        if delta != 0 {
            for index in (first + paragraphs.count)..<ranges.count {
                ranges[index].location += delta
            }
        }
        length = text.length
        return changed
    }

    private func paragraph(at location: Int) -> Int {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].location <= location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }

    private mutating func rebuild(from text: NSAttributedString) -> Bool {
        let previous = document
        reset(from: text)
        return document != previous
    }
}
