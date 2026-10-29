import Foundation

/// The text of a message body as the search index stores it.
public enum SearchText {
    /// Characters kept per message. Words past the limit aren't searchable locally;
    /// Gmail's results still find them.
    public static let limit = 100_000

    /// The plain text part when it has any text, otherwise the HTML with
    /// `script`, `style` and `head` contents and comments dropped, tags turned
    /// into spaces and entities decoded. Whitespace runs become one space.
    public static func body(html: String?, plainText: String?) -> String {
        if let plainText, plainText.contains(where: { !$0.isWhitespace }) {
            return collapsed(plainText)
        }
        guard let html, !html.isEmpty else { return "" }
        return collapsed(HTMLEntities.decode(strippingTags(html)))
    }

    /// One pass over the bytes; every byte that marks a tag is ASCII. Stops once
    /// the output is far past what `collapsed` keeps.
    static func strippingTags(_ html: String) -> String {
        let bytes = Array(html.utf8)
        let budget = limit * 8
        var output: [UInt8] = []
        output.reserveCapacity(min(bytes.count, budget))
        var i = 0
        while i < bytes.count, output.count < budget {
            guard bytes[i] == lessThan, i + 1 < bytes.count, startsTag(bytes[i + 1]) else {
                output.append(bytes[i])
                i += 1
                continue
            }
            if matches(bytes, at: i, "<!--") {
                i = find(bytes, "-->", from: i + 4).map { $0 + 3 } ?? bytes.count
            } else if let name = skippedElement(bytes, at: i) {
                i = endOfSkippedElement(name, bytes, from: i)
            } else {
                i = endOfTag(bytes, from: i)
            }
            output.append(space)
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func collapsed(_ text: String) -> String {
        var result = ""
        var count = 0
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = count > 0
                continue
            }
            if pendingSpace {
                guard count + 1 < limit else { break }
                result.append(" ")
                count += 1
                pendingSpace = false
            }
            result.append(character)
            count += 1
            if count >= limit { break }
        }
        return result
    }

    // MARK: Bytes

    private static let lessThan = UInt8(ascii: "<")
    private static let greaterThan = UInt8(ascii: ">")
    private static let space = UInt8(ascii: " ")

    /// Elements whose contents never show as text.
    private static let skippedElements = ["script", "style", "head"]

    /// A `<` starts a tag only before a letter, `/`, `!` or `?`; `a < b` is text.
    private static func startsTag(_ byte: UInt8) -> Bool {
        isLetter(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "!") || byte == UInt8(ascii: "?")
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
    }

    /// Case-insensitive for letters.
    private static func matches(_ bytes: [UInt8], at index: Int, _ text: String) -> Bool {
        let pattern = Array(text.utf8)
        guard index + pattern.count <= bytes.count else { return false }
        for (offset, expected) in pattern.enumerated() {
            let byte = bytes[index + offset]
            if byte == expected { continue }
            guard isLetter(expected), byte | 0x20 == expected | 0x20 else { return false }
        }
        return true
    }

    private static func find(_ bytes: [UInt8], _ text: String, from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            if matches(bytes, at: i, text) { return i }
            i += 1
        }
        return nil
    }

    /// The tag name ends at a space, `>` or `/`, so `<header>` isn't `head`.
    private static func endsName(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index < bytes.count else { return true }
        let byte = bytes[index]
        return byte == greaterThan || byte == UInt8(ascii: "/") || byte <= space
    }

    private static func skippedElement(_ bytes: [UInt8], at index: Int) -> String? {
        skippedElements.first { name in
            matches(bytes, at: index + 1, name) && endsName(bytes, at: index + 1 + name.utf8.count)
        }
    }

    /// After the element's closing tag. A `head` without one also ends where
    /// `body` starts, as browsers do.
    private static func endOfSkippedElement(_ name: String, _ bytes: [UInt8], from start: Int) -> Int {
        var i = endOfTag(bytes, from: start)
        while i < bytes.count {
            if bytes[i] == lessThan {
                if matches(bytes, at: i, "</\(name)"), endsName(bytes, at: i + 2 + name.utf8.count) {
                    return endOfTag(bytes, from: i)
                }
                if name == "head", matches(bytes, at: i, "<body"), endsName(bytes, at: i + 5) {
                    return i
                }
            }
            i += 1
        }
        return bytes.count
    }

    /// After the `>` that closes the tag at `start`, skipping any `>` inside a
    /// quoted attribute value. A quote only opens a value right after `=`, so an
    /// apostrophe in an unquoted value doesn't swallow the rest of the message.
    private static func endOfTag(_ bytes: [UInt8], from start: Int) -> Int {
        var quote: UInt8?
        var previous: UInt8 = 0
        var i = start + 1
        while i < bytes.count {
            let byte = bytes[i]
            if let open = quote {
                if byte == open { quote = nil }
            } else if (byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'")) && previous == UInt8(ascii: "=") {
                quote = byte
            } else if byte == greaterThan {
                return i + 1
            }
            if byte > space { previous = byte }
            i += 1
        }
        return bytes.count
    }
}
