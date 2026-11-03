import Foundation
import GmailAPI

public struct NewsletterUnsubscribeOptions: Sendable, Equatable {
    public let listID: String?
    public let webURL: URL?
    public let mailtoURL: URL?
    public let oneClickURL: URL?

    public init(listID: String?, webURL: URL?, mailtoURL: URL?, oneClickURL: URL?) {
        self.listID = listID
        self.webURL = webURL
        self.mailtoURL = mailtoURL
        self.oneClickURL = oneClickURL
    }
}

/// Reads only the outer message's list headers. Opening or fetching a message
/// never follows an unsubscribe URL.
public enum NewsletterHeaders {
    public static let metadataHeaders = [
        "List-Id", "List-Unsubscribe", "List-Unsubscribe-Post", "Authentication-Results", "DKIM-Signature",
    ]

    public static func parse(_ message: GmailMessage) -> NewsletterUnsubscribeOptions? {
        let headers = message.payload?.headers ?? []
        let unsubscribe = values("List-Unsubscribe", in: headers)
        // Multiple list headers make the signed value and intended action ambiguous.
        guard unsubscribe.count == 1, let value = unfold(unsubscribe[0]),
              let addresses = bracketedURLs(value) else { return nil }
        let web = addresses.compactMap { NewsletterURLPolicy.webURL($0) }
        let mailto = addresses.compactMap { NewsletterURLPolicy.mailtoURL($0) }.first
        guard !web.isEmpty || mailto != nil else { return nil }

        let posts = values("List-Unsubscribe-Post", in: headers)
        let oneClick: URL?
        if posts.count == 1, unfold(posts[0]) == "List-Unsubscribe=One-Click",
           web.count == 1, addresses.filter({ $0.lowercased().hasPrefix("http:") || $0.lowercased().hasPrefix("https:") }).count == 1,
           web[0].scheme?.lowercased() == "https",
           hasVerifiedCoveringSignature(headers) {
            oneClick = web[0]
        } else { oneClick = nil }

        let ids = values("List-Id", in: headers)
        let listID = ids.count == 1 ? normalizedListID(ids[0]) : nil
        return NewsletterUnsubscribeOptions(listID: listID, webURL: web.first, mailtoURL: mailto, oneClickURL: oneClick)
    }

    private static func values(_ name: String, in headers: [MessagePart.Header]) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// Only legal CRLF folding is accepted; bare line breaks are header injection.
    private static func unfold(_ value: String) -> String? {
        guard value.utf8.count <= 32_768 else { return nil }
        let unfolded = value.replacingOccurrences(of: "\r\n[ \t]+", with: " ", options: .regularExpression)
        guard !unfolded.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" || $0.value == 127 }) else { return nil }
        return unfolded.trimmingCharacters(in: .whitespaces)
    }

    private static func bracketedURLs(_ value: String) -> [String]? {
        var remaining = value[...]
        var urls: [String] = []
        while !remaining.trimmingCharacters(in: .whitespaces).isEmpty {
            remaining = remaining.drop(while: { $0 == " " || $0 == "\t" })
            guard remaining.first == "<", let close = remaining.firstIndex(of: ">") else { return nil }
            let address = String(remaining[remaining.index(after: remaining.startIndex)..<close])
            guard !address.contains("<"), !address.isEmpty else { return nil }
            urls.append(address)
            remaining = remaining[remaining.index(after: close)...].drop(while: { $0 == " " || $0 == "\t" })
            if remaining.isEmpty { break }
            guard remaining.first == "," else { return nil }
            remaining = remaining.dropFirst()
            guard !remaining.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            guard urls.count < 20 else { return nil }
        }
        return urls.isEmpty ? nil : urls
    }

    private static func normalizedListID(_ value: String) -> String? {
        guard let text = unfold(value), let start = text.firstIndex(of: "<"),
              let end = text[start...].firstIndex(of: ">"),
              text[text.index(after: end)...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let id = text[text.index(after: start)..<end]
        guard !id.isEmpty, id.count <= 998, !id.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) else { return nil }
        return id.lowercased()
    }

    /// Gmail is the receiver and trust boundary here. Only its first
    /// Authentication-Results field can authenticate an action; later fields
    /// and ARC's reports about an upstream receiver are not trusted.
    private static func hasVerifiedCoveringSignature(_ headers: [MessagePart.Header]) -> Bool {
        guard let first = values("Authentication-Results", in: headers).first,
              let authentication = unfold(first),
              let clean = removingComments(authentication) else { return false }
        let sections = clean.split(separator: ";", omittingEmptySubsequences: false)
        guard sections.first?.trimmingCharacters(in: .whitespaces).lowercased() == "mx.google.com" else { return false }
        let verified = sections.dropFirst().compactMap { section -> [String: String]? in
            let tokens = section.split(whereSeparator: \.isWhitespace)
            guard tokens.first?.lowercased() == "dkim=pass" else { return nil }
            var fields: [String: String] = [:]
            for token in tokens.dropFirst() {
                let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return nil }
                let key = pair[0].lowercased()
                guard fields[key] == nil else { return nil }
                fields[key] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            return fields
        }
        guard !verified.isEmpty else { return false }

        let signatures = values("DKIM-Signature", in: headers).compactMap { value in
            unfold(value).flatMap(signatureTags)
        }
        return verified.contains { result in
            let matches = signatures.filter { tags in
                guard let domain = tags["d"]?.lowercased(), let selector = tags["s"],
                      let signatureBytes = tags["b"].map({ $0.filter { !$0.isWhitespace } }) else { return false }
                // header.b identifies the exact signature, not an unrelated
                // passing signature on the same message or signing domain.
                guard let prefix = result["header.b"], prefix.count >= 8,
                      signatureBytes.hasPrefix(prefix), result["header.s"] == selector else { return false }
                if let signedDomain = result["header.d"] { return signedDomain.lowercased() == domain }
                guard let identity = result["header.i"], let at = identity.lastIndex(of: "@") else { return false }
                let identityDomain = identity[identity.index(after: at)...].lowercased()
                return identityDomain == domain || identityDomain.hasSuffix("." + domain)
            }
            // An attacker can copy b= from a passing signature into another
            // signature with different h= tags. An ambiguous identity fails closed.
            guard matches.count == 1, let signedHeaders = matches[0]["h"]?.lowercased().split(separator: ":") else { return false }
            let names = Set(signedHeaders.map { $0.trimmingCharacters(in: .whitespaces) })
            return names.contains("list-unsubscribe") && names.contains("list-unsubscribe-post")
        }
    }

    private static func signatureTags(_ value: String) -> [String: String]? {
        var tags: [String: String] = [:]
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, tags[key] == nil else { return nil }
            tags[key] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        return tags
    }

    private static func removingComments(_ value: String) -> String? {
        var depth = 0
        var escaped = false
        var result = ""
        for character in value {
            if escaped { escaped = false; if depth == 0 { return nil }; continue }
            if character == "\\" { escaped = true; continue }
            if character == "(" { depth += 1; continue }
            if character == ")" { guard depth > 0 else { return nil }; depth -= 1; continue }
            if depth == 0 { result.append(character) }
        }
        return depth == 0 && !escaped ? result : nil
    }
}

/// Syntactic URL checks also apply to links opened for manual completion.
/// Automated requests additionally validate every resolved address.
public enum NewsletterURLPolicy {
    public static func webURL(_ value: String, requiresHTTPS: Bool = false) -> URL? {
        guard validURLText(value), let url = URL(string: value, encodingInvalidCharacters: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              (requiresHTTPS ? scheme == "https" : ["http", "https"].contains(scheme)),
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || components.port == (scheme == "https" ? 443 : 80),
              let host = components.host, isPublicHostname(host) else { return nil }
        return url
    }

    public static func mailtoURL(_ value: String) -> URL? {
        guard validURLText(value, allowsEncodedNewlines: true), let url = URL(string: value, encodingInvalidCharacters: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "mailto", components.host == nil,
              components.fragment == nil, components.user == nil, components.password == nil,
              components.queryItems?.allSatisfy({ ["subject", "body"].contains($0.name.lowercased()) }) ?? true,
              let request = try? MailtoParser.parse(url), request.to.count == 1,
              request.cc.isEmpty, request.bcc.isEmpty,
              let address = request.to.first?.address, address.count <= 320,
              components.path.caseInsensitiveCompare(address) == .orderedSame,
              let host = address.split(separator: "@").last, isPublicHostname(String(host)) else { return nil }
        return url
    }

    public static func isPublicHostname(_ value: String) -> Bool {
        let host = value.lowercased()
        guard host.count <= 253, !host.hasSuffix("."),
              !["localhost", "local", "internal", "home", "lan", "invalid", "test", "example", "onion"].contains(where: {
                  host == $0 || host.hasSuffix("." + $0)
              }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, last.contains(where: { ("a"..."z").contains($0) }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    private static func validURLText(_ value: String, allowsEncodedNewlines: Bool = false) -> Bool {
        !value.isEmpty && value.utf8.count <= 8_192
            && !value.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 }
            && !(allowsEncodedNewlines ? ["%00"] : ["%00", "%0a", "%0d"]).contains(where: { value.lowercased().contains($0) })
    }
}
