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

/// One attachment in a `full`-format payload.
public struct AttachmentPart: Sendable, Equatable {
    /// Stable across fetches, unlike `attachmentID`.
    public var partID: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Nil when Gmail put the bytes in the payload, which it does for small parts.
    public var attachmentID: String?
    /// Shown inside the message, such as an image the HTML loads through a `cid:` URL.
    public var isInline: Bool
}

/// Picks the text parts and attachments out of a `full`-format Gmail payload.
///
/// Gmail undoes the transfer encoding but leaves the bytes in the part's
/// declared charset, so each part is decoded here.
public enum MIMEParts {
    public static func body(of message: GmailMessage, attachments: [String: Data] = [:]) -> ExtractedBody {
        guard let payload = message.payload else { return ExtractedBody() }
        let found = collect(payload, attachments: attachments)
        return ExtractedBody(
            html: found.html.isEmpty ? nil : found.html.joined(separator: "\n"),
            plainText: found.plain.isEmpty ? nil : found.plain.joined(separator: "\n")
        )
    }

    /// Readable body parts, optionally including the next calendar candidate.
    /// Further calendar candidates are requested through `CalendarParts`.
    public static func requiredAttachmentIDs(of message: GmailMessage, includingCalendars: Bool = false) -> Set<String> {
        func collect(_ part: MessagePart) -> Set<String> {
            guard !isAttachment(part) else { return [] }
            if (part.mimeType ?? "").lowercased().hasPrefix("multipart/") {
                return (part.parts ?? []).reduce(into: Set<String>()) { $0.formUnion(collect($1)) }
            }
            guard ["text/plain", "text/html"].contains((part.mimeType ?? "").lowercased()),
                  part.body?.decodedData == nil, let id = part.body?.attachmentId else { return [] }
            return [id]
        }
        var ids = message.payload.map(collect) ?? []
        if includingCalendars, let calendarID = CalendarParts.requiredAttachmentID(of: message) {
            ids.insert(calendarID)
        }
        return ids
    }

    /// Parts with a file name or an attachment disposition, in payload order.
    /// An attached message with its own bytes is listed once, not by its parts.
    public static func attachments(of message: GmailMessage) -> [AttachmentPart] {
        guard let payload = message.payload else { return [] }
        var found: [AttachmentPart] = []
        collectAttachments(payload, into: &found)
        return found
    }

    private static func collectAttachments(_ part: MessagePart, into found: inout [AttachmentPart]) {
        let children = part.parts ?? []
        let hasBytes = part.body?.attachmentId != nil || part.body?.decodedData != nil
        guard isAttachment(part), hasBytes || children.isEmpty, let partID = part.partId else {
            for child in children { collectAttachments(child, into: &found) }
            return
        }
        let contentType = part.header("Content-Type")
        let disposition = part.header("Content-Disposition")?.trimmingCharacters(in: .whitespaces).lowercased()
        let filename = part.filename.flatMap { $0.isEmpty ? nil : $0 }
            ?? contentType.flatMap { MIMEReader.parameters(of: $0)["name"] }.map(MIMEReader.decodeEncodedWords)
            ?? "Attachment"
        let isInline = disposition.map { $0.hasPrefix("inline") }
            ?? (part.header("Content-ID") != nil)
        found.append(AttachmentPart(
            partID: partID,
            filename: filename,
            mimeType: (part.mimeType ?? "application/octet-stream").lowercased(),
            size: part.body?.size ?? 0,
            attachmentID: part.body?.attachmentId,
            isInline: isInline
        ))
    }

    private struct Found {
        var html: [String] = []
        var plain: [String] = []
    }

    private static func collect(_ part: MessagePart, attachments: [String: Data]) -> Found {
        guard !isAttachment(part) else { return Found() }
        let mimeType = (part.mimeType ?? "").lowercased()

        if mimeType.hasPrefix("multipart/") {
            let children = (part.parts ?? []).map { collect($0, attachments: attachments) }
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

        guard let data = part.body?.decodedData ?? part.body?.attachmentId.flatMap({ attachments[$0] }) else { return Found() }
        let charset = part.header("Content-Type").flatMap { MIMEReader.parameters(of: $0)["charset"] }
        switch mimeType {
        case "text/html": return Found(html: [decode(data, charset: charset)])
        case "text/plain": return Found(plain: [decode(data, charset: charset)])
        default: return Found()
        }
    }

    static func isAttachment(_ part: MessagePart) -> Bool {
        if let filename = part.filename, !filename.isEmpty { return true }
        return part.header("Content-Disposition")?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix("attachment") ?? false
    }

    /// Decodes text in its declared charset, reading the label as the WHATWG
    /// Encoding Standard does. Declared UTF-8 always decodes, with U+FFFD for
    /// each bad sequence. Latin-1 labels mean Windows-1252, since senders
    /// label Windows-1252 text that way, and the Chinese, Korean, Japanese and
    /// Big5 labels mean their Windows supersets. Text with no label, an unknown one
    /// or bytes its charset can't decode is read as UTF-8 when it's valid
    /// UTF-8 and as Windows-1252 otherwise.
    static func decode(_ data: Data, charset: String?) -> String {
        let label = charset?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if utf8Labels.contains(label) { return utf8(data) }
        if windows1252Labels.contains(label) { return windows1252(data) }
        if let encoding = supersetLabels[label], let text = String(data: data, encoding: encoding) { return text }
        // The standard reads ASCII labels as Windows-1252 too. They go to the
        // guess instead, which does the same unless the text is valid UTF-8,
        // as mail labeled ASCII often is.
        if !asciiLabels.contains(label), let encoding = encoding(forIANAName: label),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(data: data, encoding: .utf8) ?? windows1252(data)
    }

    /// The standard's labels for UTF-8.
    private static let utf8Labels: Set<String> = [
        "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8",
    ]
    /// The standard's labels for Windows-1252, apart from the ASCII ones.
    private static let windows1252Labels: Set<String> = [
        "cp1252", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100", "iso8859-1", "iso88591",
        "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "windows-1252", "x-cp1252",
    ]
    /// The standard's labels for Windows-1252 that name ASCII.
    private static let asciiLabels: Set<String> = ["ansi_x3.4-1968", "ascii", "us-ascii"]
    /// The standard's Chinese, Korean, Japanese and Big5 labels. Each reads as
    /// the Windows superset of the charset it names, because senders put the
    /// superset's characters behind the older label, and Foundation rejects
    /// the whole text for one of them.
    private static let supersetLabels: [String: String.Encoding] = {
        func encoding(_ value: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
        }
        let families: [(CFStringEncodings, [String])] = [
            (.GB_18030_2000, ["chinese", "csgb2312", "csiso58gb231280", "gb18030", "gb2312", "gb_2312", "gb_2312-80",
                              "gbk", "iso-ir-58", "x-gbk"]),
            (.dosKorean, ["cseuckr", "csksc56011987", "euc-kr", "iso-ir-149", "korean", "ks_c_5601-1987", "ks_c_5601-1989",
                          "ksc5601", "ksc_5601", "windows-949"]),
            (.dosJapanese, ["csshiftjis", "ms932", "ms_kanji", "shift-jis", "shift_jis", "sjis", "windows-31j", "x-sjis"]),
            (.big5_HKSCS_1999, ["big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5"]),
        ]
        var labels: [String: String.Encoding] = [:]
        for (value, names) in families {
            for name in names { labels[name] = encoding(value) }
        }
        return labels
    }()

    /// UTF-8 as the standard decodes it: a leading byte order mark is
    /// dropped, and each bad sequence becomes U+FFFD.
    private static func utf8(_ data: Data) -> String {
        let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
        return String(decoding: data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data, as: UTF8.self)
    }

    /// Windows-1252 as the standard decodes it, which gives every byte a
    /// character.
    private static func windows1252(_ data: Data) -> String {
        // Foundation's decoder is faster, but it rejects any text with a byte
        // Windows leaves undefined.
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(data.count)
        for byte in data {
            scalars.append((0x80...0x9F).contains(byte) ? windows1252From0x80[Int(byte) - 0x80] : Unicode.Scalar(byte))
        }
        return String(scalars)
    }

    /// The characters for 0x80 to 0x9F, where Windows-1252 differs from
    /// Latin-1. Every other byte is the code point with its own number, and
    /// so are the five bytes Windows leaves undefined: 0x81, 0x8D, 0x8F, 0x90
    /// and 0x9D.
    private static let windows1252From0x80: [Unicode.Scalar] = [
        "\u{20AC}", "\u{0081}", "\u{201A}", "\u{0192}", "\u{201E}", "\u{2026}", "\u{2020}", "\u{2021}",
        "\u{02C6}", "\u{2030}", "\u{0160}", "\u{2039}", "\u{0152}", "\u{008D}", "\u{017D}", "\u{008F}",
        "\u{0090}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2022}", "\u{2013}", "\u{2014}",
        "\u{02DC}", "\u{2122}", "\u{0161}", "\u{203A}", "\u{0153}", "\u{009D}", "\u{017E}", "\u{0178}",
    ]

    private static func encoding(forIANAName name: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}
