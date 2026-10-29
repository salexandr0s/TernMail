import Foundation

/// One entity of a raw RFC 5322 message: its headers, and either a body after
/// transfer decoding or its child parts.
struct MIMEEntity: Sendable {
    struct Header: Sendable, Equatable {
        let name: String
        let value: String
    }

    var headers: [Header]
    var body = Data()
    var parts: [MIMEEntity] = []

    /// The first header with this name, unfolded but not decoded.
    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var mimeType: String {
        header("Content-Type")?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
    }

    /// Senders put encoded words in either parameter, though RFC 2231 is the standard.
    var filename: String? {
        let name = header("Content-Disposition").flatMap { MIMEReader.parameters(of: $0)["filename"] }
            ?? header("Content-Type").flatMap { MIMEReader.parameters(of: $0)["name"] }
        return name.map(MIMEReader.decodeEncodedWords)
    }

    /// The body as text in its declared charset, for `text/*` parts.
    var text: String? {
        guard mimeType.hasPrefix("text/") else { return nil }
        let charset = header("Content-Type").flatMap { MIMEReader.parameters(of: $0)["charset"] }
        return MIMEParts.decode(body, charset: charset)
    }
}

/// Reads raw RFC 5322 messages. Gmail hands Tern parsed JSON for stored mail,
/// so this checks what `MIMEWriter` produces and reads headers that arrive raw.
enum MIMEReader {
    static func parse(_ data: Data) -> MIMEEntity {
        let (headerBytes, body) = splitHeaders(Data(data))
        var entity = MIMEEntity(headers: parseHeaders(headerBytes))
        if entity.mimeType.hasPrefix("multipart/"),
           let boundary = entity.header("Content-Type").flatMap({ parameters(of: $0)["boundary"] }) {
            entity.parts = splitMultipart(body, boundary: boundary).map(parse)
        } else {
            entity.body = decodeTransfer(body, encoding: entity.header("Content-Transfer-Encoding"))
        }
        return entity
    }

    private static func splitHeaders(_ data: Data) -> (Data, Data) {
        if data.starts(with: Data("\r\n".utf8)) { return (Data(), Data(data.dropFirst(2))) }
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = data.range(of: Data(separator.utf8)) {
                return (Data(data[..<range.lowerBound]), Data(data[range.upperBound...]))
            }
        }
        return (data, Data())
    }

    private static func parseHeaders(_ data: Data) -> [MIMEEntity.Header] {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            // Unfolding removes the line break and keeps the whitespace after it.
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += line
            } else {
                lines.append(String(line))
            }
        }
        return lines.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return MIMEEntity.Header(
                name: line[..<colon].trimmingCharacters(in: .whitespaces),
                value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            )
        }
    }

    /// The parts between delimiter lines. The line break before a delimiter belongs to it.
    private static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var partStart: Data.Index?
        var searchFrom = body.startIndex
        while let range = body.range(of: delimiter, in: searchFrom..<body.endIndex) {
            searchFrom = range.upperBound
            let atLineStart = range.lowerBound == body.startIndex || body[range.lowerBound - 1] == 0x0A
            let next = range.upperBound < body.endIndex ? body[range.upperBound] : 0x0A
            // A longer boundary that starts with this one isn't a delimiter.
            guard atLineStart, [0x2D, 0x0D, 0x0A, 0x20, 0x09].contains(next) else { continue }
            if let start = partStart {
                var end = range.lowerBound
                if end > start, body[end - 1] == 0x0A { end -= 1 }
                if end > start, body[end - 1] == 0x0D { end -= 1 }
                parts.append(Data(body[start..<end]))
            }
            if body[range.upperBound...].starts(with: Data("--".utf8)) { break }
            guard let lineEnd = body[range.upperBound...].firstIndex(of: 0x0A) else { break }
            partStart = lineEnd + 1
            searchFrom = lineEnd + 1
        }
        return parts
    }

    private static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            return Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = Array(data)
        var output = Data()
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                index += 2
            } else if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                index += 3
            } else if index + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(value)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    // MARK: Headers

    /// Parameters of a header such as `attachment; filename*=UTF-8''%E2%82%AC.pdf`,
    /// with names lowercased and RFC 2231 sections joined and decoded.
    static func parameters(of headerValue: String) -> [String: String] {
        var pieces: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for character in headerValue {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", inQuote {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                current.append(character)
                inQuote.toggle()
            } else if character == ";", !inQuote {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)

        var result: [String: String] = [:]
        var sections: [String: [(index: Int, value: String, extended: Bool)]] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = unescapeQuoted(String(value.dropFirst().dropLast()))
            }
            guard name.contains("*") else {
                result[name] = value
                continue
            }
            let extended = name.hasSuffix("*")
            if extended { name.removeLast() }
            var index = 0
            if let star = name.firstIndex(of: "*") {
                index = Int(name[name.index(after: star)...]) ?? 0
                name = String(name[..<star])
            }
            sections[name, default: []].append((index, value, extended))
        }
        for (name, list) in sections {
            var charset: String?
            var bytes = Data()
            for (position, section) in list.sorted(by: { $0.index < $1.index }).enumerated() {
                guard section.extended else {
                    bytes += Data(section.value.utf8)
                    continue
                }
                var value = Substring(section.value)
                if position == 0 {
                    let fields = section.value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 {
                        charset = fields[0].isEmpty ? nil : String(fields[0])
                        value = fields[2]
                    }
                }
                bytes += percentDecoded(value)
            }
            result[name] = MIMEParts.decode(bytes, charset: charset ?? "utf-8")
        }
        return result
    }

    private static func unescapeQuoted(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped || character != "\\" {
                result.append(character)
                escaped = false
            } else {
                escaped = true
            }
        }
        return result
    }

    private static func percentDecoded(_ value: Substring) -> Data {
        let bytes = Array(value.utf8)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(byte)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    /// Decodes RFC 2047 encoded words. Whitespace between two encoded words is
    /// dropped, and adjacent words in one charset are decoded together, since
    /// some senders split a character across words.
    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        // Regex isn't Sendable, so it can't be a shared static.
        let encodedWord = #/=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?=/#
        var result = ""
        var pending = Data()
        var pendingCharset: String?
        var cursor = value.startIndex

        func flush() {
            guard !pending.isEmpty else { return }
            result += MIMEParts.decode(pending, charset: pendingCharset)
            pending = Data()
            pendingCharset = nil
        }

        for match in value.matches(of: encodedWord) {
            let between = value[cursor..<match.range.lowerBound]
            let charset = match.output.1.split(separator: "*").first.map(String.init)?.lowercased()
            guard let bytes = decodeWord(encoding: match.output.2, text: match.output.3) else { continue }
            let joinsPrevious = !pending.isEmpty && between.allSatisfy(\.isWhitespace)
            if !joinsPrevious {
                flush()
                result += between
            } else if charset != pendingCharset {
                flush()
            }
            pending += bytes
            pendingCharset = charset
            cursor = match.range.upperBound
        }
        flush()
        result += value[cursor...]
        return result
    }

    private static func decodeWord(encoding: Substring, text: Substring) -> Data? {
        if encoding.lowercased() == "b" {
            return Data(base64Encoded: String(text), options: .ignoreUnknownCharacters)
        }
        let underscoresAsSpaces = text.replacingOccurrences(of: "_", with: " ")
        return decodeQuotedPrintable(Data(underscoresAsSpaces.utf8))
    }
}
