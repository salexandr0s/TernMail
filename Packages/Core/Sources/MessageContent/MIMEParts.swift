import Foundation
import GmailAPI

/// The readable text of one message, before sanitizing.
public struct ExtractedBody: Sendable, Equatable {
    public var html: String?
    public var plainText: String?

    public init(html: String? = nil, plainText: String? = nil) {
        self.html = html
        self.plainText = plainText
    }

    public var isEmpty: Bool { html == nil && plainText == nil }
}

/// Picks the text parts out of a `full`-format Gmail payload.
///
/// Gmail undoes the transfer encoding but leaves the bytes in the part's
/// declared charset, so each part is decoded here.
public enum MIMEParts {
    public static func body(of message: GmailMessage) -> ExtractedBody {
        guard let payload = message.payload else { return ExtractedBody() }
        let found = collect(payload)
        return ExtractedBody(
            html: found.html.isEmpty ? nil : found.html.joined(separator: "\n"),
            plainText: found.plain.isEmpty ? nil : found.plain.joined(separator: "\n")
        )
    }

    private struct Found {
        var html: [String] = []
        var plain: [String] = []
    }

    private static func collect(_ part: MessagePart) -> Found {
        let mimeType = (part.mimeType ?? "").lowercased()

        if mimeType.hasPrefix("multipart/") {
            let children = (part.parts ?? []).map(collect)
            if mimeType == "multipart/alternative" {
                // Alternatives are ordered plainest first; keep the richest of each kind.
                var found = Found()
                found.html = children.last { !$0.html.isEmpty }?.html ?? []
                found.plain = children.last { !$0.plain.isEmpty }?.plain ?? []
                return found
            }
            return children.reduce(into: Found()) { result, child in
                result.html += child.html
                result.plain += child.plain
            }
        }

        guard !isAttachment(part), let data = part.body?.decodedData else { return Found() }
        let charset = part.header("Content-Type").flatMap { parameter("charset", in: $0) }
        switch mimeType {
        case "text/html": return Found(html: [decode(data, charset: charset)])
        case "text/plain": return Found(plain: [decode(data, charset: charset)])
        default: return Found()
        }
    }

    private static func isAttachment(_ part: MessagePart) -> Bool {
        if let filename = part.filename, !filename.isEmpty { return true }
        return part.header("Content-Disposition")?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix("attachment") ?? false
    }

    /// Decodes with the declared charset, then UTF-8, then Windows-1252 and
    /// Latin-1, which accept almost any byte sequence.
    static func decode(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(forIANAName: charset),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        for encoding in [String.Encoding.utf8, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func encoding(forIANAName name: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    /// Reads a parameter such as `charset` from a header like
    /// `text/plain; charset="iso-8859-1"`.
    static func parameter(_ name: String, in headerValue: String) -> String? {
        for piece in headerValue.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name
            else { continue }
            let value = pair[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
