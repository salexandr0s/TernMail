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
}
