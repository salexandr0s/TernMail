import Foundation

public struct MailtoRequest: Sendable, Equatable {
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var body: String

    public init(to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [], subject: String = "", body: String = "") {
        self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject; self.body = body
    }
}

/// RFC 6068 fields Tern can place in an editable draft. Plus signs remain literal.
public enum MailtoParser {
    public enum Failure: Error, Sendable, Equatable { case invalidURL, invalidAddress, invalidHeader }

    public static func parse(_ url: URL) throws -> MailtoRequest {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "mailto", components.host == nil, components.fragment == nil,
              let path = components.percentEncodedPath.removingPercentEncoding else { throw Failure.invalidURL }
        var result = MailtoRequest(to: try addresses(path))
        var hasSubject = false
        var hasBody = false
        for entry in (components.percentEncodedQuery ?? "").split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = String(pieces[0]).removingPercentEncoding,
                  let value = (pieces.count > 1 ? String(pieces[1]) : "").removingPercentEncoding else { throw Failure.invalidURL }
            switch name.lowercased() {
            case "to": result.to += try addresses(value)
            case "cc": result.cc += try addresses(value)
            case "bcc": result.bcc += try addresses(value)
            case "subject":
                guard !hasSubject, !value.contains(where: \.isNewline), !value.contains("\0") else { throw Failure.invalidHeader }
                result.subject = value; hasSubject = true
            case "body":
                guard !hasBody, !value.contains("\0") else { throw Failure.invalidHeader }
                result.body = value.replacingOccurrences(of: "\r\n", with: "\n"); hasBody = true
            default: break // Headers such as From, Reply-To and attachment cannot affect the draft.
            }
        }
        result.to = unique(result.to)
        result.cc = unique(result.cc)
        result.bcc = unique(result.bcc)
        return result
    }

    private static func addresses(_ value: String) throws -> [EmailAddress] {
        guard !value.contains(where: \.isNewline), !value.contains("\0") else { throw Failure.invalidHeader }
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let parsed = EmailAddress.parseList(value)
        guard !parsed.isEmpty, parsed.allSatisfy(\.isValid) else { throw Failure.invalidAddress }
        return parsed
    }

    private static func unique(_ values: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.normalized).inserted }
    }
}
