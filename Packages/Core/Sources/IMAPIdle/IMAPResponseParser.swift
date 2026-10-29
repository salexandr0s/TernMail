import Foundation

/// A server response, reduced to what an IDLE watcher needs. Free text is
/// dropped, so a response can't carry an address or a server message into
/// a log.
public enum IMAPResponse: Sendable, Equatable {
    public enum Status: String, Sendable {
        case ok = "OK"
        case no = "NO"
        case bad = "BAD"
    }

    public enum Condition: String, Sendable {
        case ok = "OK"
        case no = "NO"
        case bad = "BAD"
        case preauth = "PREAUTH"
        case bye = "BYE"
    }

    /// The bracketed code after a status, such as `[CAPABILITY IMAP4rev1 IDLE]`.
    public struct Code: Sendable, Equatable {
        /// Upper-cased.
        public var name: String
        public var arguments: [String]

        public init(name: String, arguments: [String] = []) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// `+`: the server waits for more from the client.
    case continuation
    case tagged(tag: String, status: Status, code: Code?)
    /// An untagged OK, NO, BAD, PREAUTH or BYE.
    case condition(Condition, code: Code?)
    /// Upper-cased capability names.
    case capability([String])
    case exists(Int)
    case expunge(Int)
    case fetch(Int)
    /// Any other untagged response, by name, such as FLAGS or RECENT.
    case other(String)
}

public enum IMAPProtocolError: Error, Sendable, Equatable {
    case lineTooLong
    case literalTooLong
    case malformedResponse
}

/// Splits the bytes a server sends into responses. Bytes can arrive in
/// chunks of any size. Literals (`{n}` and then n bytes) are skipped by their
/// byte count, so line breaks inside them don't end the line.
public struct IMAPResponseParser: Sendable {
    /// Longer lines, literals not counted, are a protocol error.
    public static let maxLineLength = 65_536
    public static let maxLiteralLength = 1_048_576

    private var line: [UInt8] = []
    private var literalRemaining = 0

    public init() {}

    /// The responses that `bytes` completes. After an error the parser's
    /// state is undefined, and the connection should close.
    public mutating func feed(_ bytes: some Sequence<UInt8>) throws -> [IMAPResponse] {
        var responses: [IMAPResponse] = []
        for byte in bytes {
            if literalRemaining > 0 {
                literalRemaining -= 1
                continue
            }
            guard byte == 0x0A else {
                guard line.count < Self.maxLineLength else { throw IMAPProtocolError.lineTooLong }
                line.append(byte)
                continue
            }
            if line.last == 0x0D { line.removeLast() }
            if let length = try takeLiteralLength() {
                literalRemaining = length
            } else {
                responses.append(try Self.parse(line))
                line.removeAll(keepingCapacity: true)
            }
        }
        return responses
    }

    /// When the line ends in `{n}`, swaps that for an empty quoted string, so
    /// the rest still parses, and returns n.
    private mutating func takeLiteralLength() throws -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        let digits = line[(open + 1)..<(line.count - 1)]
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        let length = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        guard length <= Self.maxLiteralLength else { throw IMAPProtocolError.literalTooLong }
        line.removeSubrange(open...)
        line += Array(#""""#.utf8)
        return length
    }

    static func parse(_ bytes: [UInt8]) throws -> IMAPResponse {
        let text = String(decoding: bytes, as: UTF8.self)
        // Tags can't contain "+", so this is always a continuation.
        if text.first == "+" { return .continuation }
        let (tag, rest) = word(text[...])
        guard !tag.isEmpty, !rest.isEmpty else { throw IMAPProtocolError.malformedResponse }
        if tag == "*" { return try untagged(rest) }
        let (status, afterStatus) = word(rest)
        guard let status = IMAPResponse.Status(rawValue: status.uppercased()) else { throw IMAPProtocolError.malformedResponse }
        return .tagged(tag: String(tag), status: status, code: code(afterStatus))
    }

    private static func untagged(_ text: Substring) throws -> IMAPResponse {
        let (first, rest) = word(text)
        if !first.isEmpty, first.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(first) {
            let name = word(rest).0.uppercased()
            switch name {
            case "EXISTS": return .exists(number)
            case "EXPUNGE": return .expunge(number)
            case "FETCH": return .fetch(number)
            case "": throw IMAPProtocolError.malformedResponse
            default: return .other(name)
            }
        }
        let name = first.uppercased()
        if let condition = IMAPResponse.Condition(rawValue: name) { return .condition(condition, code: code(rest)) }
        if name == "CAPABILITY" { return .capability(rest.split(separator: " ").map { $0.uppercased() }) }
        guard !name.isEmpty else { throw IMAPProtocolError.malformedResponse }
        return .other(name)
    }

    /// `[NAME arguments]` at the start of `text`, if there is one.
    private static func code(_ text: Substring) -> IMAPResponse.Code? {
        guard text.first == "[", let close = text.firstIndex(of: "]") else { return nil }
        let parts = text[text.index(after: text.startIndex)..<close].split(separator: " ").map(String.init)
        guard let name = parts.first else { return nil }
        return IMAPResponse.Code(name: name.uppercased(), arguments: Array(parts.dropFirst()))
    }

    /// The text up to the first space, and the text after it.
    private static func word(_ text: Substring) -> (Substring, Substring) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (text[..<space], text[text.index(after: space)...])
    }
}
