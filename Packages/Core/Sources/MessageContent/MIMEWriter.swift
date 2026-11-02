import Foundation

/// A message to encode as RFC 5322 bytes for Gmail's upload endpoints.
public struct MIMEMessage: Sendable, Equatable {
    public struct Attachment: Sendable, Equatable {
        public var filename: String
        public var mimeType: String
        public var data: Data
        public var contentID: String?

        public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
            self.contentID = contentID
        }
    }

    /// A validated calendar alternative whose MIME method matches its body.
    public struct CalendarPart: Sendable, Equatable {
        public let text: String
        public let method: String

        public init(text: String) throws {
            let calendar = try ICalendar.parse(Data(text.utf8))
            let methods = calendar.properties(named: "METHOD")
            guard methods.count == 1, let method = methods.first?.value, !method.isEmpty,
                  // A folded " method=" prefix leaves 990 bytes on the line.
                  method.utf8.count <= 990,
                  method.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { throw ICalendarError.malformed }
            self.method = method
            // Keep only the component that was validated, with canonical CRLF
            // and folding. The parser may ignore data after its first root.
            self.text = calendar.serialized()
        }
    }

    public var from: EmailAddress
    public var replyTo: [EmailAddress] = []
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    /// Gmail drops the Bcc header from what recipients get, so it belongs in
    /// the uploaded message.
    public var bcc: [EmailAddress] = []
    public var subject = ""
    public var date = Date()
    /// Message IDs include their angle brackets, like `<id@example.com>`.
    public var messageID: String?
    /// An optional RFC 8098 request, addressed to the sending identity.
    public var dispositionNotificationTo: EmailAddress?
    public var inReplyTo: String?
    public var references: [String] = []
    public var plainText = ""
    public var html: String?
    public var calendarPart: CalendarPart?
    public var attachments: [Attachment] = []

    public init(from: EmailAddress) {
        self.from = from
    }

    /// A new Message-ID on the sender's domain.
    public static func newMessageID(for sender: EmailAddress) -> String {
        let domain = sender.address.split(separator: "@").last.map(String.init) ?? "localhost"
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    /// The message with CRLF line endings, in 7-bit ASCII: quoted-printable
    /// text, base64 attachments and RFC 2047 encoded words in headers.
    public func encoded(timeZone: TimeZone = .current) -> Data {
        var headers = [
            MIMEWriter.header("Date", MIMEWriter.dateString(date, timeZone: timeZone)),
            MIMEWriter.addressHeader("From", [from]),
        ]
        if !replyTo.isEmpty { headers.append(MIMEWriter.addressHeader("Reply-To", replyTo)) }
        if !to.isEmpty { headers.append(MIMEWriter.addressHeader("To", to)) }
        if !cc.isEmpty { headers.append(MIMEWriter.addressHeader("Cc", cc)) }
        if !bcc.isEmpty { headers.append(MIMEWriter.addressHeader("Bcc", bcc)) }
        headers.append(MIMEWriter.unstructuredHeader("Subject", subject))
        if let messageID = MIMEWriter.messageIDs([messageID].compactMap { $0 }).first {
            headers.append(MIMEWriter.header("Message-ID", messageID))
        }
        if let recipient = dispositionNotificationTo, recipient.isValid,
           !recipient.address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            headers.append(MIMEWriter.addressHeader("Disposition-Notification-To", [recipient]))
        }
        if let inReplyTo = MIMEWriter.messageIDs([inReplyTo].compactMap { $0 }).first {
            headers.append(MIMEWriter.header("In-Reply-To", inReplyTo))
        }
        let references = MIMEWriter.messageIDs(references)
        if !references.isEmpty {
            headers.append(MIMEWriter.fold("References", references, separator: ""))
        }
        headers.append("MIME-Version: 1.0")

        let body = MIMEWriter.body(of: self)
        let text = (headers + body.headers).joined(separator: "\r\n") + "\r\n\r\n" + body.content
        return Data(text.utf8)
    }
}

/// The encoders behind `MIMEMessage`. Everything they return is ASCII.
enum MIMEWriter {
    struct Entity {
        var headers: [String]
        var content: String
    }

    /// Header lines may run to 998 characters but should stay under 78.
    private static let preferredLineLength = 78
    /// UTF-8 bytes per encoded word: 45 bytes is 60 base64 characters, which
    /// keeps each word within RFC 2047's 75.
    private static let encodedWordBytes = 45

    static func body(of message: MIMEMessage) -> Entity {
        let plain = textEntity(message.plainText, subtype: "plain")
        var alternatives = [plain]
        let inline = message.html == nil ? [] : message.attachments.filter { validContentID($0.contentID) != nil }
        if let html = message.html {
            let entity = textEntity(html, subtype: "html")
            alternatives.append(inline.isEmpty ? entity : multipart("related", [entity] + inline.map(attachmentEntity)))
        }
        if let calendar = message.calendarPart { alternatives.append(calendarEntity(calendar)) }
        let main = alternatives.count == 1 ? plain : multipart("alternative", alternatives)
        let ordinary = message.attachments.filter { message.html == nil || validContentID($0.contentID) == nil }
        guard !ordinary.isEmpty else { return main }
        return multipart("mixed", [main] + ordinary.map(attachmentEntity))
    }

    private static func textEntity(_ text: String, subtype: String) -> Entity {
        Entity(
            headers: [
                "Content-Type: text/\(subtype); charset=UTF-8",
                "Content-Transfer-Encoding: quoted-printable",
            ],
            content: quotedPrintable(text)
        )
    }

    private static func calendarEntity(_ calendar: MIMEMessage.CalendarPart) -> Entity {
        Entity(
            headers: [
                fold("Content-Type", ["text/calendar;", "charset=UTF-8;", "method=\(calendar.method)"], separator: ""),
                "Content-Disposition: inline",
                "Content-Transfer-Encoding: quoted-printable",
            ],
            content: quotedPrintable(calendar.text)
        )
    }

    private static func multipart(_ subtype: String, _ parts: [Entity]) -> Entity {
        // "=_" never appears in quoted-printable or base64 output, so no part
        // can contain the boundary.
        let boundary = "=_tern_\(UUID().uuidString)"
        var content = ""
        for part in parts {
            content += "--\(boundary)\r\n" + part.headers.joined(separator: "\r\n") + "\r\n\r\n" + part.content + "\r\n"
        }
        content += "--\(boundary)--"
        return Entity(headers: ["Content-Type: multipart/\(subtype); boundary=\"\(boundary)\""], content: content)
    }

    private static func attachmentEntity(_ attachment: MIMEMessage.Attachment) -> Entity {
        let filename = headerSafe(attachment.filename)
        let isASCII = filename.allSatisfy(\.isASCII)
        // The Content-Type name is for older clients; RFC 2231 names are the standard.
        let name = isASCII ? quoted(filename) : "\"\(encodedWords(filename).joined(separator: " "))\""
        let contentID = validContentID(attachment.contentID)
        var disposition = "Content-Disposition: \(contentID == nil ? "attachment" : "inline");"
        if isASCII {
            disposition += "\r\n filename=\(quoted(filename))"
        } else {
            let sections = rfc2231Sections(filename)
            for (index, section) in sections.enumerated() {
                let key = sections.count == 1 ? "filename*" : "filename*\(index)*"
                let value = index == 0 ? "UTF-8''\(section)" : section
                disposition += "\r\n \(key)=\(value)" + (index < sections.count - 1 ? ";" : "")
            }
        }
        return Entity(
            headers: [
                "Content-Type: \(mimeType(attachment.mimeType));\r\n name=\(name)",
                disposition,
                "Content-Transfer-Encoding: base64",
            ] + (contentID.map { ["Content-ID: <\($0)>"] } ?? []),
            content: attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        )
    }

    private static func validContentID(_ value: String?) -> String? {
        guard let value, InlineImageReference(contentID: value).isValid else { return nil }
        return value
    }

    // MARK: Headers

    static func header(_ name: String, _ value: String) -> String {
        "\(name): \(headerSafe(value))"
    }

    static func addressHeader(_ name: String, _ addresses: [EmailAddress]) -> String {
        let values = addresses.map { address in
            EmailAddress(name: address.name.map(headerSafe), address: headerSafe(address.address).filter { !$0.isWhitespace })
                .headerValue
        }
        return fold(name, values, separator: ",")
    }

    /// Folds at word boundaries. A value with non-ASCII text or a word too long
    /// to fold becomes encoded words.
    static func unstructuredHeader(_ name: String, _ value: String) -> String {
        let value = headerSafe(value)
        let words = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let fitsAsASCII = value.allSatisfy(\.isASCII)
            && !value.contains("=?")
            && words.allSatisfy { $0.count < preferredLineLength - name.count - 2 }
        if fitsAsASCII {
            return fold(name, words, separator: "")
        }
        return "\(name): " + encodedWords(value).joined(separator: "\r\n ")
    }

    /// Joins `items` with `separator` and a space, starting a new line before
    /// an item that would pass the preferred length.
    static func fold(_ name: String, _ items: [String], separator: String) -> String {
        var result = "\(name):"
        var lineLength = result.count
        for (index, item) in items.enumerated() {
            let piece = item + (index < items.count - 1 ? separator : "")
            if lineLength + 1 + piece.count > preferredLineLength, lineLength > name.count + 1 {
                result += "\r\n "
                lineLength = 1
            } else {
                result += " "
                lineLength += 1
            }
            result += piece
            lineLength += piece.count
        }
        return result
    }

    /// A display name as an RFC 5322 phrase: bare, quoted or encoded.
    static func phrase(_ name: String) -> String {
        let name = headerSafe(name)
        guard name.allSatisfy(\.isASCII), !name.contains("=?") else {
            return encodedWords(name).joined(separator: " ")
        }
        let atext = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$%&'*+-/=?^_`{|}~ "))
        if name.unicodeScalars.allSatisfy(atext.contains) { return name }
        return quoted(name)
    }

    /// Base64 encoded words of at most `encodedWordBytes` each, split between
    /// characters so no word holds part of one.
    static func encodedWords(_ text: String) -> [String] {
        var words: [String] = []
        var chunk = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if !chunk.isEmpty, chunk.count + bytes.count > encodedWordBytes {
                words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
                chunk = Data()
            }
            chunk += bytes
        }
        if !chunk.isEmpty || words.isEmpty {
            words.append("=?UTF-8?B?\(chunk.base64EncodedString())?=")
        }
        return words
    }

    /// RFC 2231 percent-encoded UTF-8, in sections short enough for one line each.
    static func rfc2231Sections(_ value: String) -> [String] {
        let attributeCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_`|~".utf8)
        var sections: [String] = []
        var current = ""
        for byte in value.utf8 {
            let token = attributeCharacters.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
            if current.count + token.count > 54 {
                sections.append(current)
                current = ""
            }
            current += token
        }
        sections.append(current)
        return sections
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Removes line breaks and other control characters, so a value can't end
    /// its header and start another.
    static func headerSafe(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{2028}" || scalar == "\u{2029}" ? " " : Character(scalar)
        })
    }

    /// The IDs that have the `<left@right>` shape, without whitespace or controls.
    static func messageIDs(_ ids: [String]) -> [String] {
        ids.compactMap { id in
            let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.hasPrefix("<"), id.hasSuffix(">"), id.contains("@"), id.count > 4,
                  id.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }),
                  id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return id
        }
    }

    /// A `type/subtype` token, or `application/octet-stream` when the given one isn't.
    static func mimeType(_ value: String) -> String {
        let token = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$&^_.+-"))
        let pieces = value.lowercased().split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.unicodeScalars.allSatisfy(token.contains) })
        else { return "application/octet-stream" }
        return pieces.joined(separator: "/")
    }

    static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    // MARK: Body

    /// RFC 2045 quoted-printable over UTF-8, with CRLF line breaks and lines of
    /// at most 76 characters.
    static func quotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(quotedPrintableLine)
            .joined(separator: "\r\n")
    }

    private static func quotedPrintableLine(_ line: Substring) -> String {
        let bytes = Array(line.utf8)
        var output = ""
        var length = 0
        for (index, byte) in bytes.enumerated() {
            let isLast = index == bytes.count - 1
            let token: String
            switch byte {
            // Trailing whitespace may be stripped in transit, so it is encoded.
            case 0x20 where !isLast, 0x09 where !isLast:
                token = String(UnicodeScalar(byte))
            case 0x21...0x7E where byte != UInt8(ascii: "="):
                token = String(UnicodeScalar(byte))
            default:
                token = String(format: "=%02X", byte)
            }
            // Leave room for the "=" of a soft line break.
            if length + token.count > 75 {
                output += "=\r\n"
                length = 0
            }
            output += token
            length += token.count
        }
        return output
    }
}
