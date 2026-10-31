import Foundation
import MessageContent

/// The words a search looks for, set in bold where a row's subject or preview
/// contains them. Matching follows the local index: whole words, ignoring case
/// and accents, with the last word typed matching as a prefix.
struct SearchHighlights: Equatable {
    /// A word or phrase from the query, as the words it matches in order.
    private struct Term: Equatable {
        let words: [String]
        let lastIsPrefix: Bool
    }

    /// How far into a preview its first match can start before the preview
    /// starts near the match instead, so one line still shows it.
    private static let previewLead = 40

    private var terms: [Term] = []
    /// Terms from `subject:`, which match only the subject.
    private var subjectTerms: [Term] = []

    init() {}

    init(_ query: SearchQuery) {
        if let root = query.root { collect(root) }
    }

    func subject(_ text: String) -> AttributedString {
        Self.highlighted(text, matching: terms + subjectTerms, excerpt: false)
    }

    /// The preview with its matches in bold. When the first match starts too
    /// far in for one line, the preview starts two words before it.
    func preview(_ text: String) -> AttributedString {
        Self.highlighted(text, matching: terms, excerpt: true)
    }

    private mutating func collect(_ node: SearchQuery.Node) {
        switch node {
        case .all(let nodes), .any(let nodes):
            nodes.forEach { collect($0) }
        case .not:
            // Results lack the words after a minus, so there's nothing to show.
            break
        case .term(.word(let text, let isPrefix)):
            if let term = Self.term(text, isPrefix: isPrefix) { terms.append(term) }
        case .term(.phrase(let text)):
            if let term = Self.term(text, isPrefix: false) { terms.append(term) }
        case .term(.field(.subject, let text)):
            if let term = Self.term(text, isPrefix: false) { subjectTerms.append(term) }
        case .term:
            break
        }
    }

    private static func term(_ text: String, isPrefix: Bool) -> Term? {
        let words = wordRanges(in: text).map { String(text[$0]) }
        return words.isEmpty ? nil : Term(words: words, lastIsPrefix: isPrefix)
    }

    private static func highlighted(_ text: String, matching terms: [Term], excerpt: Bool) -> AttributedString {
        guard !terms.isEmpty else { return AttributedString(text) }
        let words = wordRanges(in: text)
        let matches = terms.flatMap { Self.matches(of: $0, in: text, words: words) }.sorted { $0.lowerBound < $1.lowerBound }
        var result = AttributedString()
        var cursor = text.startIndex
        if excerpt, let first = matches.first, text.distance(from: text.startIndex, to: first.lowerBound) > previewLead,
           let index = words.firstIndex(where: { $0.lowerBound == first.lowerBound }), index > 2 {
            cursor = words[index - 2].lowerBound
            result.append(AttributedString("…"))
        }
        for match in matches where match.upperBound > cursor {
            let start = max(match.lowerBound, cursor)
            result.append(AttributedString(String(text[cursor..<start])))
            var bold = AttributedString(String(text[start..<match.upperBound]))
            bold.inlinePresentationIntent = .stronglyEmphasized
            result.append(bold)
            cursor = match.upperBound
        }
        result.append(AttributedString(String(text[cursor...])))
        return result
    }

    /// Where the term's words appear one after another, each from the start
    /// of a word.
    private static func matches(of term: Term, in text: String, words: [Range<String.Index>]) -> [Range<String.Index>] {
        guard words.count >= term.words.count else { return [] }
        return (0...(words.count - term.words.count)).compactMap { first in
            var end = words[first].lowerBound
            for (offset, word) in term.words.enumerated() {
                let range = words[first + offset]
                let isPrefix = term.lastIsPrefix && offset == term.words.count - 1
                guard let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .anchored], range: range),
                      isPrefix || found.upperBound == range.upperBound else { return nil }
                end = found.upperBound
            }
            return words[first].lowerBound..<end
        }
    }

    /// The runs of letters and digits that the index treats as words.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isLetter || text[index].isNumber {
                if start == nil { start = index }
            } else if let wordStart = start {
                ranges.append(wordStart..<index)
                start = nil
            }
        }
        if let start { ranges.append(start..<text.endIndex) }
        return ranges
    }
}
