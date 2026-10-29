import Foundation

/// A search written in Gmail's query syntax, parsed once so the local index and
/// Gmail answer the same question.
///
/// Terms next to each other must all match. `OR` binds tighter than that, so
/// `a b OR c` means `a AND (b OR c)`, as in Gmail. `{a b}` means `a OR b`, and
/// `-` negates the term or group after it. Only operators Gmail documents count
/// as operators, so `10:30` stays a word.
public struct SearchQuery: Sendable, Equatable {
    public indirect enum Node: Sendable, Equatable {
        case term(Term)
        case all([Node])
        case any([Node])
        case not(Node)
    }

    public enum Term: Sendable, Equatable {
        /// A word to find in any indexed column. The query's last word matches as
        /// a prefix when nothing follows it, for search as you type.
        case word(String, isPrefix: Bool)
        case phrase(String)
        /// A word or phrase limited to one header.
        case field(Field, String)
        /// A `label:` value as written. The store matches it against label names.
        case labelName(String)
        /// A Gmail label ID, from `is:`, `in:` and `category:`.
        case labelID(String)
        /// `in:anywhere`, which matches every message.
        case anywhere
        case date(DateBound)
        /// A part only Gmail can answer, as written.
        case gmailOnly(String)
    }

    public enum Field: String, Sendable {
        case from, to, cc, subject
    }

    public enum DateBound: Sendable, Equatable {
        /// `after:`, `newer:` and `newer_than:`.
        case onOrAfter(DateValue)
        /// `before:`, `older:` and `older_than:`.
        case before(DateValue)
    }

    public enum DateValue: Sendable, Equatable {
        /// A Gregorian calendar day, starting at midnight in the searcher's time zone.
        case day(year: Int, month: Int, day: Int)
        case epochSeconds(Int64)
        case ago(Int, DateUnit)
    }

    public enum DateUnit: Sendable {
        case days, months, years
    }

    public let text: String
    /// Nil when nothing in the query can be searched locally.
    public let root: Node?
    /// Spam and Trash are searched only when the query names them, as in Gmail.
    public let includesSpamAndTrash: Bool
    private let days: [DayOperand]

    public init(_ text: String) {
        var parser = Parser(text: text, tokens: Self.tokens(in: text))
        self.text = text
        root = parser.parse()
        includesSpamAndTrash = parser.includesSpamAndTrash
        days = parser.days
    }

    /// Whether the local index can answer the whole query exactly. False when a
    /// part has no local meaning, and when a word or phrase is negated: bodies of
    /// unopened messages aren't indexed, so `-word` would wrongly match them.
    public var runsLocally: Bool {
        root.map { Self.isLocal($0, negated: false) } ?? false
    }

    /// The text to send to Gmail as `q`. Calendar days become epoch seconds,
    /// since Gmail reads a day as midnight Pacific time.
    public func gmailQuery(timeZone: TimeZone) -> String {
        var result = text
        // Later ranges first, so earlier ones stay valid.
        for day in days.reversed() {
            guard let start = DateValue.day(year: day.year, month: day.month, day: day.day)
                .date(in: timeZone, now: .distantPast) else { continue }
            result.replaceSubrange(day.range, with: String(Int64(start.timeIntervalSince1970)))
        }
        return result
    }

    private static func isLocal(_ node: Node, negated: Bool) -> Bool {
        switch node {
        case .term(.gmailOnly): false
        case .term(.word), .term(.phrase): !negated
        case .term: true
        case .all(let nodes), .any(let nodes): nodes.allSatisfy { isLocal($0, negated: negated) }
        case .not(let node): isLocal(node, negated: !negated)
        }
    }
}

extension SearchQuery.DateValue {
    /// The instant this value stands for. Days use the Gregorian calendar, as
    /// Gmail's syntax does, whatever calendar the Mac is set to.
    public func date(in timeZone: TimeZone, now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch self {
        case .day(let year, let month, let day):
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        case .epochSeconds(let seconds):
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        case .ago(let amount, let unit):
            let component: Calendar.Component = switch unit {
            case .days: .day
            case .months: .month
            case .years: .year
            }
            return calendar.date(byAdding: component, value: -amount, to: now)
        }
    }
}

// MARK: Tokens

extension SearchQuery {
    /// A calendar day in the query, kept with its place in the text for the Gmail rewrite.
    struct DayOperand: Sendable, Equatable {
        let range: Range<String.Index>
        let year: Int
        let month: Int
        let day: Int
    }

    struct Token {
        enum Kind: Equatable {
            case open, close, openBrace, closeBrace, minus, or, and
            case phrase(String)
            case word(String)
            case op(name: String, value: String, valueRange: Range<String.Index>)
            /// `subject:(`: the group's tokens follow, up to the matching `)`.
            case opGroup(String)

            var opensGroup: Bool {
                switch self {
                case .open, .opGroup: true
                default: false
                }
            }
        }

        let kind: Kind
        let range: Range<String.Index>
    }

    /// The operators Gmail's search help documents. Any other `name:value` is a word.
    static let operators: Set<String> = [
        "from", "to", "cc", "bcc", "subject", "label", "category", "has", "list", "filename",
        "in", "is", "after", "before", "older", "newer", "older_than", "newer_than",
        "deliveredto", "size", "larger", "smaller", "rfc822msgid",
    ]

    static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        func isBoundary(_ character: Character) -> Bool {
            character.isWhitespace || "(){}\"".contains(character)
        }
        func add(_ kind: Token.Kind, _ range: Range<String.Index>) {
            tokens.append(Token(kind: kind, range: range))
        }

        while i < text.endIndex {
            let character = text[i]
            let next = text.index(after: i)
            switch character {
            case _ where character.isWhitespace:
                i = next
            case "(":
                add(.open, i..<next)
                i = next
            case ")":
                add(.close, i..<next)
                i = next
            case "{":
                add(.openBrace, i..<next)
                i = next
            case "}":
                add(.closeBrace, i..<next)
                i = next
            case "\"":
                let quote = quoted(text, at: i)
                add(.phrase(String(text[quote.content])), i..<quote.end)
                i = quote.end
            case "-" where next < text.endIndex && !text[next].isWhitespace:
                add(.minus, i..<next)
                i = next
            default:
                var end = i
                while end < text.endIndex, !isBoundary(text[end]) { end = text.index(after: end) }
                let word = text[i..<end]
                if word == "OR" {
                    add(.or, i..<end)
                } else if word == "AND" {
                    add(.and, i..<end)
                } else if let colon = word.firstIndex(of: ":"), operators.contains(word[..<colon].lowercased()) {
                    let name = word[..<colon].lowercased()
                    let valueStart = text.index(after: colon)
                    if valueStart < end {
                        add(.op(name: name, value: String(text[valueStart..<end]), valueRange: valueStart..<end), i..<end)
                    } else if end < text.endIndex, text[end] == "\"" {
                        let quote = quoted(text, at: end)
                        add(.op(name: name, value: String(text[quote.content]), valueRange: quote.content), i..<quote.end)
                        end = quote.end
                    } else if end < text.endIndex, text[end] == "(" {
                        end = text.index(after: end)
                        add(.opGroup(name), i..<end)
                    } else {
                        add(.word(String(word)), i..<end)
                    }
                } else {
                    add(.word(String(word)), i..<end)
                }
                i = end
            }
        }
        return tokens
    }

    /// The text inside a quote starting at `start`, and where the quote ends.
    /// A quote missing its closing mark runs to the end of the text.
    private static func quoted(
        _ text: String, at start: String.Index
    ) -> (content: Range<String.Index>, end: String.Index) {
        let contentStart = text.index(after: start)
        guard let close = text[contentStart...].firstIndex(of: "\"") else {
            return (contentStart..<text.endIndex, text.endIndex)
        }
        return (contentStart..<close, text.index(after: close))
    }
}

// MARK: Parsing

extension SearchQuery {
    struct Parser {
        let text: String
        let tokens: [Token]
        var index = 0
        /// Set inside `from:( … )` and the like: words and phrases there belong to the field.
        var field: Field?
        var includesSpamAndTrash = false
        var days: [DayOperand] = []

        mutating func parse() -> Node? {
            Self.combine(parseSequence(until: nil), into: Node.all)
        }

        /// Terms up to `end`, which is consumed. Stray closing marks and
        /// operators with nothing to join are skipped, so any input parses.
        private mutating func parseSequence(until end: Token.Kind?) -> [Node] {
            var nodes: [Node] = []
            while index < tokens.count {
                let kind = tokens[index].kind
                if kind == end {
                    index += 1
                    break
                }
                if [.close, .closeBrace, .or, .and].contains(kind) {
                    index += 1
                    continue
                }
                if let node = parseOr() { nodes.append(node) }
            }
            return nodes
        }

        private mutating func parseOr() -> Node? {
            var alternatives = parseUnary().map { [$0] } ?? []
            while index < tokens.count, tokens[index].kind == .or {
                index += 1
                if let next = parseUnary() { alternatives.append(next) }
            }
            return Self.combine(alternatives, into: Node.any)
        }

        /// One term or group. Leaves closing marks and `OR` for the caller.
        private mutating func parseUnary() -> Node? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            switch token.kind {
            case .close, .closeBrace, .or, .and:
                return nil
            default:
                index += 1
            }
            switch token.kind {
            case .minus:
                return parseUnary().map(Node.not)
            case .open:
                return Self.combine(parseSequence(until: .close), into: Node.all)
            case .openBrace:
                return Self.combine(parseSequence(until: .closeBrace), into: Node.any)
            case .phrase(let phrase):
                guard Self.hasSearchableText(phrase) else { return nil }
                return .term(field.map { .field($0, phrase) } ?? .phrase(phrase))
            case .word(let word):
                return wordNode(word, range: token.range)
            case .op(let name, let value, let valueRange):
                return operatorNode(name: name, value: value, valueRange: valueRange, raw: String(text[token.range]))
            case .opGroup(let name):
                return operatorGroup(name: name, start: token.range.lowerBound)
            case .close, .closeBrace, .or, .and:
                return nil
            }
        }

        private func wordNode(_ word: String, range: Range<String.Index>) -> Node? {
            // Gmail-only syntax: exact-word match and proximity.
            if word == "AROUND" || (word.hasPrefix("+") && word.count > 1) { return .term(.gmailOnly(word)) }
            // Gmail ignores punctuation on its own; so does the index.
            guard Self.hasSearchableText(word) else { return nil }
            if let field { return .term(.field(field, word)) }
            return .term(.word(word, isPrefix: range.upperBound == text.endIndex))
        }

        private mutating func operatorNode(
            name: String, value: String, valueRange: Range<String.Index>, raw: String
        ) -> Node {
            let gmailOnly = Node.term(.gmailOnly(raw))
            let lowered = value.lowercased()
            switch name {
            case "from", "to", "cc", "subject":
                guard let field = Field(rawValue: name), Self.hasSearchableText(value) else { return gmailOnly }
                return .term(.field(field, value))
            case "label":
                if ["trash", "spam"].contains(lowered) { includesSpamAndTrash = true }
                return .term(.labelName(value))
            case "is":
                switch lowered {
                case "unread": return .term(.labelID("UNREAD"))
                case "read": return .not(.term(.labelID("UNREAD")))
                case "starred": return .term(.labelID("STARRED"))
                case "important": return .term(.labelID("IMPORTANT"))
                default: return gmailOnly
                }
            case "in":
                switch lowered {
                case "inbox": return .term(.labelID("INBOX"))
                case "sent": return .term(.labelID("SENT"))
                case "draft", "drafts": return .term(.labelID("DRAFT"))
                case "trash", "spam":
                    includesSpamAndTrash = true
                    return .term(.labelID(lowered.uppercased()))
                case "anywhere":
                    includesSpamAndTrash = true
                    return .term(.anywhere)
                default:
                    return gmailOnly
                }
            case "category":
                let ids = [
                    "primary": "CATEGORY_PERSONAL", "personal": "CATEGORY_PERSONAL", "social": "CATEGORY_SOCIAL",
                    "promotions": "CATEGORY_PROMOTIONS", "updates": "CATEGORY_UPDATES", "forums": "CATEGORY_FORUMS",
                ]
                return ids[lowered].map { Node.term(.labelID($0)) } ?? gmailOnly
            case "after", "newer", "before", "older":
                guard let date = absoluteDate(lowered, range: valueRange) else { return gmailOnly }
                return .term(.date(["after", "newer"].contains(name) ? .onOrAfter(date) : .before(date)))
            case "newer_than", "older_than":
                guard let date = Self.relativeDate(lowered) else { return gmailOnly }
                return .term(.date(name == "newer_than" ? .onOrAfter(date) : .before(date)))
            default:
                return gmailOnly
            }
        }

        /// `subject:(dinner movie)` applies the field to every word inside. Other
        /// operators with a group are left to Gmail.
        private mutating func operatorGroup(name: String, start: String.Index) -> Node? {
            if let groupField = Field(rawValue: name) {
                let outer = field
                field = groupField
                defer { field = outer }
                return Self.combine(parseSequence(until: .close), into: Node.all)
            }
            var depth = 1
            var end = text.endIndex
            while index < tokens.count {
                let token = tokens[index]
                index += 1
                if token.kind.opensGroup {
                    depth += 1
                } else if token.kind == .close {
                    depth -= 1
                    if depth == 0 {
                        end = token.range.upperBound
                        break
                    }
                }
            }
            return .term(.gmailOnly(String(text[start..<end])))
        }

        /// `2026/01/15`, `01/15/2026` or epoch seconds. Nil for anything else,
        /// including days that don't exist.
        private mutating func absoluteDate(_ value: String, range: Range<String.Index>) -> DateValue? {
            if !value.isEmpty, value.allSatisfy(\.isASCIIDigit) {
                return Int64(value).map(DateValue.epochSeconds)
            }
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else {
                return nil
            }
            let numbers = parts.compactMap { Int($0) }
            guard numbers.count == 3 else { return nil }
            let (year, month, day): (Int, Int, Int)
            if parts[0].count == 4 {
                (year, month, day) = (numbers[0], numbers[1], numbers[2])
            } else if parts[2].count == 4 {
                (year, month, day) = (numbers[2], numbers[0], numbers[1])
            } else {
                return nil
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
            guard DateComponents(year: year, month: month, day: day).isValidDate(in: calendar) else { return nil }
            days.append(DayOperand(range: range, year: year, month: month, day: day))
            return .day(year: year, month: month, day: day)
        }

        /// `3d`, `2m` or `1y`.
        private static func relativeDate(_ value: String) -> DateValue? {
            guard let unitCharacter = value.last else { return nil }
            let unit: DateUnit
            switch unitCharacter {
            case "d": unit = .days
            case "m": unit = .months
            case "y": unit = .years
            default: return nil
            }
            let digits = value.dropLast()
            guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let amount = Int(digits) else { return nil }
            return .ago(amount, unit)
        }

        private static func hasSearchableText(_ text: String) -> Bool {
            text.contains { $0.isLetter || $0.isNumber }
        }

        private static func combine(_ nodes: [Node], into make: ([Node]) -> Node) -> Node? {
            switch nodes.count {
            case 0: nil
            case 1: nodes[0]
            default: make(nodes)
            }
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
