import Foundation

/// One mailbox from an address header: an optional display name and the address.
public struct EmailAddress: Sendable, Hashable, Codable {
    public var name: String?
    public var address: String

    public init(name: String? = nil, address: String) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name?.isEmpty == false ? name : nil
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// The mailbox as written in a header, with the name quoted or encoded as needed.
    var headerValue: String {
        guard let name else { return address }
        return "\(MIMEWriter.phrase(name)) <\(address)>"
    }

    /// Parses an address header such as `"Doe, Jane" <jane@example.com>, bob@example.com`.
    /// Group names are dropped and their members kept. Entries without an
    /// "@" are skipped.
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
    var results: [EmailAddress] = []
    private var phrase = ""
    private var angle: String?
    private var comment = ""
    private var lastComment: String?
    private var inQuote = false
    private var inAngle = false
    private var commentDepth = 0
    private var escaped = false

    /// Takes the next character, and says whether it was a separator that ended an entry.
    @discardableResult
    mutating func consume(_ character: Character) -> Bool {
        if escaped {
            append(character)
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
            case "\"": inQuote = false
            default: phrase.append(character)
            }
        } else if inAngle {
            if character == ">" { inAngle = false } else { angle?.append(character) }
        } else {
            switch character {
            case "\"": inQuote = true
            case "(": commentDepth = 1
            case "<":
                inAngle = true
                angle = ""
            case ",", ";":
                finishEntry()
                return true
            // A group's name ends at the colon; its members follow.
            case ":" where angle == nil: phrase = ""
            default: phrase.append(character)
            }
        }
        return false
    }

    private mutating func append(_ character: Character) {
        if commentDepth > 0 {
            comment.append(character)
        } else if inAngle {
            angle?.append(character)
        } else {
            phrase.append(character)
        }
    }

    mutating func finishEntry() {
        defer {
            phrase = ""
            angle = nil
            comment = ""
            lastComment = nil
            inQuote = false
            inAngle = false
            commentDepth = 0
            escaped = false
        }
        let text = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var address: String
        var name: String?
        if var angle {
            // Drop an obsolete source route such as "@relay.example:".
            if let colon = angle.lastIndex(of: ":") { angle = String(angle[angle.index(after: colon)...]) }
            address = angle.trimmingCharacters(in: .whitespaces)
            name = text.isEmpty ? lastComment : text
        } else {
            // A bare address. Stray words around it aren't a name.
            address = text.split(separator: " ").first { $0.contains("@") }.map(String.init) ?? ""
            name = lastComment
        }
        guard address.contains("@") else { return }
        results.append(EmailAddress(name: name.map(MIMEReader.decodeEncodedWords), address: address))
    }
}
