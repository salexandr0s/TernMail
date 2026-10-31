import Foundation

/// Encodes and decodes Google's `multipart/mixed` batch format.
/// See https://developers.google.com/gmail/api/guides/batch.
enum BatchCodec {
    struct Part: Equatable {
        let contentID: String?
        let status: Int
        let body: Data
        var retryAfter: String? = nil

        /// The request index from a response `Content-ID` such as `<response-item-3>`.
        var itemIndex: Int? {
            guard let contentID, let range = contentID.range(of: "item-", options: .backwards) else {
                return nil
            }
            return Int(contentID[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "<> ")))
        }
    }

    static func encode(_ endpoints: [Endpoint], boundary: String) throws -> Data {
        var data = Data()
        for (index, endpoint) in endpoints.enumerated() {
            var head = "--\(boundary)\r\n"
            head += "Content-Type: application/http\r\n"
            head += "Content-ID: <item-\(index)>\r\n\r\n"
            head += "\(endpoint.method) \(try endpoint.requestTarget()) HTTP/1.1\r\n"
            if let body = endpoint.body {
                head += "Content-Type: application/json\r\n"
                head += "Content-Length: \(body.count)\r\n\r\n"
                data.append(Data(head.utf8))
                data.append(body)
                data.append(Data("\r\n".utf8))
            } else {
                head += "\r\n"
                data.append(Data(head.utf8))
            }
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// The boundary parameter of a `multipart/mixed` content type, quoted or not.
    static func boundary(contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";") {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary"
            else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return nil
    }

    static func decode(_ data: Data, boundary: String) throws -> [Part] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GmailError.decoding("Batch response is not UTF-8")
        }
        // JSON escapes control characters inside strings, so raw CRLFs only occur
        // between tokens and normalizing them cannot change a body's meaning.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var parts: [Part] = []
        // A delimiter starts a MIME line. Boundary text inside a JSON string
        // is ordinary content, not the start of another part.
        for chunk in ("\n" + normalized).components(separatedBy: "\n--" + boundary).dropFirst() {
            if chunk.hasPrefix("--") { break }
            parts.append(try decodePart(chunk))
        }
        return parts
    }

    private static func decodePart(_ chunk: String) throws -> Part {
        let trimmed = String(chunk.drop { $0 == "\n" })
        guard let (outerHeaders, embedded) = splitAtBlankLine(trimmed) else {
            throw GmailError.decoding("Batch part has no embedded response")
        }
        let (head, body) = splitAtBlankLine(embedded) ?? (embedded, "")
        let statusLine = head.split(separator: "\n", maxSplits: 1).first ?? ""
        let fields = statusLine.split(separator: " ")
        guard fields.count >= 2, let status = Int(fields[1]) else {
            throw GmailError.decoding("Batch part has no status line")
        }
        return Part(
            contentID: headerValue("Content-ID", in: outerHeaders),
            status: status,
            body: Data(body.trimmingCharacters(in: .newlines).utf8),
            retryAfter: headerValue("Retry-After", in: head)
        )
    }

    private static func splitAtBlankLine(_ text: String) -> (String, String)? {
        guard let range = text.range(of: "\n\n") else { return nil }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    private static func headerValue(_ name: String, in headers: String) -> String? {
        for line in headers.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
