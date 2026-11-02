import Foundation
import SwiftSoup

public enum SenderProfileLinkKind: String, Codable, Sendable, CaseIterable {
    case linkedin, instagram, facebook, x, github, youtube, tiktok, mastodon, website

    public var label: String {
        switch self {
        case .linkedin: "LinkedIn"
        case .instagram: "Instagram"
        case .facebook: "Facebook"
        case .x: "X"
        case .github: "GitHub"
        case .youtube: "YouTube"
        case .tiktok: "TikTok"
        case .mastodon: "Mastodon"
        case .website: "Website"
        }
    }
}

public struct SenderProfileLink: Codable, Equatable, Sendable, Identifiable {
    public let kind: SenderProfileLinkKind
    public let url: URL
    public let label: String
    public var id: String { url.absoluteString }

    public init(kind: SenderProfileLinkKind, url: URL, label: String) {
        self.kind = kind
        self.url = url
        self.label = label
    }
}

/// Finds links supplied in a sender's signature. It makes no network requests
/// and does not infer ownership of a profile or website from the address.
public enum SenderProfileLinks {
    public static let maximumInputBytes = 131_072
    private static let maximumLinks = 12
    private static let signatureStart = "TERN_SIGNATURE_START_51E9"
    private static let signatureEnd = "TERN_SIGNATURE_END_51E9"
    private static let forwardedBoundary = "TERN_FORWARD_BOUNDARY_51E9"

    public static func extract(plainText: String?, html: String?) -> [SenderProfileLink] {
        var candidates: [String] = []
        if let html, html.utf8.count <= maximumInputBytes, let text = signatureText(html) {
            candidates += urls(in: signatureRegion(text))
        }
        // Reject oversized inputs rather than treating a truncated body as its footer.
        if let plainText, plainText.utf8.count <= maximumInputBytes {
            candidates += urls(in: signatureRegion(plainText))
        }
        var seen = Set<String>()
        var links: [SenderProfileLink] = []
        for candidate in candidates.prefix(64) {
            guard let link = normalizedLink(candidate) else { continue }
            let identity = link.url.absoluteString.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            if seen.insert(identity).inserted { links.append(link) }
            if links.count == maximumLinks { break }
        }
        return links
    }

    private static func signatureText(_ html: String) -> String? {
        do {
            let document = try SwiftSoup.parse(html)
            try document.select("script,style,head,blockquote,.gmail_quote,.yahoo_quoted,.protonmail_quote,[type=cite],[hidden],[aria-hidden=true]").remove()
            for marker in try document.select("#divRplyFwdMsg,.gmail_attr,.moz-cite-prefix").array() {
                try marker.prependText("\n\(forwardedBoundary)\n")
            }
            for signature in try document.select(".gmail_signature,.moz-signature,#signature,#Signature,[data-smartmail=gmail_signature]").array() {
                try signature.prependText("\n\(signatureStart)\n")
                try signature.appendText("\n\(signatureEnd)\n")
            }
            // Icon-only anchors retain their destination without loading the image.
            for anchor in try document.select("a[href]").array().prefix(128) {
                let href = try anchor.attr("href")
                // Visible link text may name a different destination. Use only
                // the validated href as evidence when HTML supplies one.
                try anchor.text(normalizedLink(href) == nil ? "" : " \(href) ")
            }
            for node in try document.select("br,p,div,li,tr,section,footer").array() {
                try node.appendText("\n")
            }
            return try document.body()?.text(trimAndNormaliseWhitespace: false)
        } catch { return nil }
    }

    private static func signatureRegion(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var authored: [String] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            let attribution = lines[index..<min(index + 3, lines.count)].joined(separator: " ").lowercased()
            if line.contains(forwardedBoundary) || lower.contains("forwarded message")
                || lower.contains("original message") || lower.contains("ursprüngliche nachricht")
                || ((lower.hasPrefix("on ") || lower.hasPrefix("am "))
                    && (attribution.contains("wrote:") || attribution.contains("schrieb"))) { break }
            if matches(#"^(?:from|von):\s"#, line),
               matches(#"(?m)^(?:to|an|sent|gesendet|subject|betreff):\s"#,
                       lines[index..<min(index + 6, lines.count)].joined(separator: "\n")) { break }
            if line.hasPrefix(">") { continue }
            authored.append(line)
        }
        if let start = authored.firstIndex(where: { $0.contains(signatureStart) }) {
            let end = authored[(start + 1)...].firstIndex(where: { $0.contains(signatureEnd) }) ?? authored.endIndex
            return authored[(start + 1)..<end].joined(separator: "\n")
        }
        if let start = authored.firstIndex(of: "--") {
            return authored.dropFirst(start + 1).prefix(24).joined(separator: "\n")
        }
        if let signature = closingSignature(authored) { return signature }
        // A short final contact block can be a signature without a sign-off.
        // Require a labelled contact field as well as a profile link; arbitrary
        // articles in the last paragraph are not sender enrichment evidence.
        while authored.last?.isEmpty == true { authored.removeLast() }
        let start = authored.lastIndex(of: "").map { $0 + 1 } ?? 0
        let footer = Array(authored[start...])
        guard (2...12).contains(footer.count), footer.allSatisfy({ $0.count <= 200 }),
              footer.contains(where: { matches(#"^(?:web(?:site)?|phone|tel(?:ephone)?|mobile|email|e-mail|linkedin|instagram|github)\s*:"#, $0) }) else { return "" }
        return footer.joined(separator: "\n")
    }

    private static func closingSignature(_ lines: [String]) -> String? {
        guard let start = lines.lastIndex(where: {
            matches(#"^(?:best(?: regards| wishes)?|kind regards|regards|thanks|thank you|many thanks|cheers|sincerely|yours(?: sincerely)?|liebe grüße|viele grüße|beste grüße|mit freundlichen grüßen|lg|vg)[,!\.]*$"#, $0)
        }), lines[..<start].contains(where: { !$0.isEmpty }) else { return nil }
        let footer = lines.dropFirst(start + 1).filter { !$0.isEmpty }
        guard (1...12).contains(footer.count), footer.allSatisfy({ line in
            line.count <= 200 && line.split(whereSeparator: \.isWhitespace).count <= 12
                && !line.hasSuffix("?") && !line.hasSuffix("!")
                && !matches(#"^(?:I|we|you|please)\s|^(?:could|can|would|will)\s+(?:you|we|I)\b|^(?:by the way|p\.?s\.?\s*:)"#, line)
        }) else { return nil }
        return footer.joined(separator: "\n")
    }

    private static func urls(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}_@/])(?:https?://|www\.)[^\s<>\"']+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).prefix(64).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?) ]}"))
        }
    }

    private static func normalizedLink(_ raw: String) -> SenderProfileLink? {
        guard raw.utf8.count <= 2_048 else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = value.lowercased().hasPrefix("www.") ? "https://" + value : value
        guard var components = URLComponents(string: absolute),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 80 || components.port == 443,
              let rawHost = components.host?.lowercased(), safeHost(rawHost) else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = components.path.lowercased()
        let segments = path.split(separator: "/").map(String.init)
        let blocked = ["unsubscribe", "optout", "opt-out", "preferences", "privacy", "terms", "login", "signin", "sign-in",
                       "logout", "share", "sharer", "sharer.php", "intent", "redirect", "redirects", "track", "tracking", "click"]
        guard !segments.contains(where: { blocked.contains($0) || $0.hasPrefix("unsubscribe") }),
              !host.hasPrefix("click."), !host.hasPrefix("track."), !host.hasPrefix("tracking.") else { return nil }
        let query = components.queryItems ?? []
        guard !query.contains(where: { ["redirect", "redirect_uri", "url", "unsubscribe", "action"].contains($0.name.lowercased()) }) else { return nil }
        guard let kind = kind(host: host, segments: segments, query: query) else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if components.port == 80 && scheme == "http" || components.port == 443 && scheme == "https" { components.port = nil }
        if components.path == "/" { components.path = "" }
        else if components.path.hasSuffix("/") { components.path.removeLast() }
        let keptQuery = query.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix("utm_") && !["fbclid", "gclid", "igshid", "igsh", "mc_cid", "mc_eid", "trk", "trackingid", "ref", "ref_src", "si"].contains(name)
        }.sorted { $0.name < $1.name }
        components.queryItems = keptQuery.isEmpty ? nil : keptQuery
        guard let url = components.url else { return nil }
        return SenderProfileLink(kind: kind, url: url, label: kind == .website ? host : kind.label)
    }

    private static func safeHost(_ host: String) -> Bool {
        guard host.count <= 253, host.contains("."), !host.hasSuffix("."),
              !host.contains(":"), !host.contains("%"),
              !host.unicodeScalars.contains(where: { !CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.").contains($0) }),
              !["localhost", "local", "internal", "lan", "home", "invalid", "test", "onion"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
            && labels.last?.contains(where: { $0.isLetter }) == true
    }

    private static func kind(host: String, segments: [String], query: [URLQueryItem]) -> SenderProfileLinkKind? {
        switch host {
        case "linkedin.com":
            return segments.count == 2 && ["in", "company", "school"].contains(segments[0]) ? .linkedin : nil
        case "instagram.com":
            return profile(segments, excluding: ["p", "reel", "reels", "stories", "explore", "accounts", "direct", "about", "legal", "challenge"]) ? .instagram : nil
        case "facebook.com", "m.facebook.com":
            if segments == ["profile.php"], query.contains(where: { $0.name == "id" && $0.value?.allSatisfy(\.isNumber) == true && $0.value?.isEmpty == false }) { return .facebook }
            if segments.count == 3, segments.first == "people" { return .facebook }
            return profile(segments, excluding: ["home.php", "watch", "groups", "events", "pages", "photo.php", "permalink.php", "help"]) ? .facebook : nil
        case "x.com", "twitter.com":
            return profile(segments, excluding: ["i", "home", "search", "explore", "compose", "settings", "messages", "hashtag"]) ? .x : nil
        case "github.com":
            return profile(segments, excluding: ["features", "topics", "explore", "marketplace", "pricing", "enterprise", "about", "orgs", "search", "settings", "notifications", "issues", "pulls"]) ? .github : nil
        case "youtube.com", "m.youtube.com":
            if segments.count == 1, segments[0].hasPrefix("@"), segments[0].count > 1 { return .youtube }
            return segments.count == 2 && ["channel", "c", "user"].contains(segments[0]) ? .youtube : nil
        case "tiktok.com":
            return segments.count == 1 && segments[0].hasPrefix("@") && segments[0].count > 1 ? .tiktok : nil
        case "mastodon.social", "mastodon.online", "fosstodon.org", "infosec.exchange", "hachyderm.io", "mstdn.social", "mas.to", "techhub.social":
            return segments.count == 1 && segments[0].hasPrefix("@") && segments[0].count > 1 ? .mastodon : nil
        case "youtu.be", "lnkd.in", "t.co", "bit.ly", "tinyurl.com": return nil
        default: return .website
        }
    }

    private static func profile(_ segments: [String], excluding: [String]) -> Bool {
        segments.count == 1 && !segments[0].isEmpty && !excluding.contains(segments[0])
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
