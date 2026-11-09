import Foundation

/// One mailbox from an address header: an optional display name and the address.
public struct EmailAddress: Sendable, Hashable, Codable {
    /// Where Tern found a recipient whose name someone else chose.
    public enum Origin: String, Sendable, Codable {
        /// A mailto link.
        case link
        /// A Reply-To that isn't the From address.
        case replyTo
    }

    public var name: String?
    public var address: String
    /// Set on a recipient from a link or a Reply-To, so its token shows the
    /// address with the name. Nil for one typed, picked or read from a header.
    public var origin: Origin?

    public init(name: String? = nil, address: String, origin: Origin? = nil) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name?.isEmpty == false ? name : nil
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.origin = origin
    }

    /// The address in lowercase, for comparing mailboxes.
    public var normalized: String { address.lowercased() }

    /// One "@" between a local part and a dotted domain, with no spaces or
    /// header punctuation. Gmail makes the real check when it sends.
    public var isValid: Bool {
        let pieces = address.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty,
              pieces[1].contains("."), !pieces[1].hasPrefix("."), !pieces[1].hasSuffix(".")
        else { return false }
        return !address.contains { $0.isWhitespace || $0.isNewline || "<>(),;:\"[]\\".contains($0) }
    }

    /// "Name <address>", or the address alone, for showing in the interface.
    public var displayString: String {
        name.map { "\($0) <\(address)>" } ?? address
    }

    /// `displayString` with the name set apart, so direction controls in it
    /// can't reorder the address. A recipient token's help.
    public var isolatedDisplayString: String {
        name.map { "\u{2068}\($0)\u{2069} <\(address)>" } ?? address
    }

    /// What a recipient's token shows: the name, unless it could pass for
    /// another mailbox. A name that looks like an address gives way to the
    /// address, and a name from a link or a Reply-To shows with it. `full`
    /// shows every name with its address.
    public func recipientTitle(full: Bool) -> String {
        guard let name, !name.isEmpty else { return address }
        if full { return isolatedDisplayString }
        if Self.looksLikeAddress(name) { return address }
        return origin == nil ? name : isolatedDisplayString
    }

    /// Whether a name could pass for an address or a domain, as
    /// `support@bank.example`, `support＠bank.example` and `bank.example` can.
    static func looksLikeAddress(_ name: String) -> Bool {
        // Compatibility forms such as "＠" and "．" read as "@" and ".", and
        // invisible format characters don't show at all.
        var scalars = name.precomposedStringWithCompatibilityMapping.unicodeScalars
        scalars.removeAll { $0.properties.generalCategory == .format }
        let text = String(scalars).replacingOccurrences(of: "\u{3002}", with: ".")
        if text.contains("@") { return true }
        // A word of dotted parts that ends in letters, as a domain does.
        return text.split(whereSeparator: \.isWhitespace).contains { word in
            let parts = word.trimmingCharacters(in: .punctuationCharacters).split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count > 1, let last = parts.last, last.count > 1 else { return false }
            return parts.allSatisfy { !$0.isEmpty } && last.allSatisfy(\.isLetter)
        }
    }

    /// The mailbox as written in a header, with the name quoted or encoded as needed.
    var headerValue: String {
        guard let name else { return address }
        return "\(MIMEWriter.phrase(name)) <\(address)>"
    }

    /// Parses an address header such as `"Doe, Jane" <jane@example.com>, bob@example.com`.
    /// Group names are dropped and their members kept. Entries without an
    /// "@" are skipped. Addresses in one entry, such as
    /// `alice@example.com bob@example.com`, are each kept.
    public static func parseList(_ header: String) -> [EmailAddress] {
        var parser = AddressListParser()
        for character in header { parser.consume(character) }
        parser.finishEntry()
        return parser.results
    }

    /// Splits recipients someone typed or pasted into entries, at the commas
    /// and semicolons `parseList` separates on. One inside quotes, a comment
    /// or angle brackets stays in its entry. A new line always ends an entry.
    /// Entries keep their spacing, and the last is empty when the text ends
    /// with a separator.
    public static func splitList(_ text: String) -> [Substring] {
        var parser = AddressListParser()
        var entries: [Substring] = []
        var start = text.startIndex
        for index in text.indices {
            let ends: Bool
            if text[index].isNewline {
                parser.finishEntry()
                ends = true
            } else {
                ends = parser.consume(text[index])
            }
            guard ends else { continue }
            entries.append(text[start..<index])
            start = text.index(after: index)
        }
        entries.append(text[start...])
        return entries
    }
}

/// A small state machine over RFC 5322 address syntax: quoted strings,
/// comments, angle brackets and groups.
private struct AddressListParser {
    /// An address the current entry holds, before its name is decoded.
    private struct Mailbox {
        var name: String?
        var address: String
    }

    /// A run of text between spaces outside quotes, comments and angle brackets.
    private struct Word {
        /// As written, with its quotes and escapes.
        var written = ""
        /// Without quotes or escapes, as a name reads.
        var plain = ""
        /// Has an "@" outside quotes, so it's an address rather than part of a name.
        var isAddress = false

        mutating func append(_ character: Character, quoted: Bool = false) {
            written.append(character)
            plain.append(character)
            if character == "@", !quoted { isAddress = true }
        }

        /// The address the word holds. Quotes that change nothing go, as in
        /// `"jane"@example.com`. A quoted local part that needs them, such as
        /// `"john doe"@example.com`, stays whole, and isn't valid.
        var address: String {
            !plain.contains(where: \.isWhitespace) && EmailAddress(address: plain).isValid ? plain : written
        }
    }

    var results: [EmailAddress] = []
    private var mailboxes: [Mailbox] = []
    /// The words since the entry's last angle address.
    private var words: [Word] = []
    private var word = Word()
    /// The text of an open angle address.
    private var angle: String?
    private var comment = ""
    private var lastComment: String?
    private var inQuote = false
    private var commentDepth = 0
    private var escaped = false

    /// Takes the next character, and says whether it was a separator that ended an entry.
    @discardableResult
    mutating func consume(_ character: Character) -> Bool {
        if escaped {
            if commentDepth > 0 {
                comment.append(character)
            } else {
                // Only quoted strings and comments have escapes.
                word.written.append("\\")
                word.append(character, quoted: true)
            }
            escaped = false
        } else if commentDepth > 0 {
            switch character {
            case "\\": escaped = true
            case "(":
                commentDepth += 1
                comment.append(character)
            case ")":
                commentDepth -= 1
                if commentDepth == 0 {
                    lastComment = comment
                    comment = ""
                } else {
                    comment.append(character)
                }
            default: comment.append(character)
            }
        } else if inQuote {
            switch character {
            case "\\": escaped = true
            case "\"":
                inQuote = false
                word.written.append(character)
            default: word.append(character, quoted: true)
            }
        } else if angle != nil {
            if character == ">" { closeAngle() } else { angle?.append(character) }
        } else {
            switch character {
            case "\"":
                inQuote = true
                word.written.append(character)
            // A comment doesn't split a word, so "jane(x)@example.com" stays one address.
            case "(": commentDepth = 1
            case "<":
                endWord()
                angle = ""
            case ",", ";":
                finishEntry()
                return true
            // A group's name ends at the colon; its members follow.
            case ":" where mailboxes.isEmpty:
                words = []
                word = Word()
            case _ where character.isWhitespace: endWord()
            default: word.append(character)
            }
        }
        return false
    }

    private mutating func endWord() {
        if !word.written.isEmpty { words.append(word) }
        word = Word()
    }

    /// Ends an angle address. The words before it are its name, even one
    /// with an "@" such as `support@bank.example <other@example.com>`.
    private mutating func closeAngle() {
        guard var text = angle else { return }
        angle = nil
        // Drop an obsolete source route such as "@relay.example:".
        if let colon = text.lastIndex(of: ":") { text = String(text[text.index(after: colon)...]) }
        mailboxes.append(Mailbox(name: Self.name(words), address: text.trimmingCharacters(in: .whitespaces)))
        words = []
    }

    mutating func finishEntry() {
        defer {
            mailboxes = []
            words = []
            word = Word()
            angle = nil
            comment = ""
            lastComment = nil
            inQuote = false
            commentDepth = 0
            escaped = false
        }
        endWord()
        closeAngle()
        // After the last angle address, each word with an "@" outside quotes
        // is an address of its own. Lacking any, a quoted word that holds a
        // whole address, as a pasted list can have, is one.
        var bare = words.filter(\.isAddress).map(\.address)
        if bare.isEmpty, mailboxes.isEmpty {
            bare = words.map(\.plain).filter { EmailAddress(address: $0).isValid }
        }
        // Other words there name a lone angle address, as in "<jane@example.com> Jane".
        if bare.isEmpty, mailboxes.count == 1, let trailing = Self.name(words) {
            mailboxes[0].name = [mailboxes[0].name, trailing].compactMap { $0 }.joined(separator: " ")
        }
        mailboxes += bare.map { Mailbox(name: nil, address: $0) }
        mailboxes.removeAll { !$0.address.contains("@") }
        // A comment names the address only when the entry has just one.
        if mailboxes.count == 1, mailboxes[0].name == nil { mailboxes[0].name = lastComment }
        results += mailboxes.map { EmailAddress(name: $0.name.map(MIMEReader.decodeEncodedWords), address: $0.address) }
    }

    /// Words as a display name, without their quotes and with single spaces.
    private static func name(_ words: [Word]) -> String? {
        let text = words.map(\.plain).joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : text
    }
}
