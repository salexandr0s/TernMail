import Foundation

/// Tern's own rules. This is a small privacy filter, not a complete tracker list.
public enum TrackerMatcher {
    public static let blockedURLPatterns = [
        #"^https?://([^/]+\.)?google-analytics\.com/"#,
        #"^https?://([^/]+\.)?doubleclick\.net/"#,
        #"^https?://([^/]+\.)?sendgrid\.net/wf/open"#,
        #"^https?://([^/]+\.)?list-manage\.com/track/open\.php"#,
        #"^https?://([^/]+\.)?mandrillapp\.com/track/open\.php"#,
    ]

    public static func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        func inDomain(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if inDomain("google-analytics.com") || inDomain("doubleclick.net") { return true }
        let path = url.path.lowercased()
        return (inDomain("sendgrid.net") && path.hasPrefix("/wf/open"))
            || ((inDomain("list-manage.com") || inDomain("mandrillapp.com")) && path == "/track/open.php")
    }

    /// Remote one-pixel images remain blocked even when other images are allowed.
    public static func isTrackingImage(url: URL, width: String?, height: String?, style: String?) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if matches(url) { return true }
        let declarations = (style ?? "").split(separator: ";").reduce(into: [String: String]()) { result, part in
            let pair = part.split(separator: ":", maxSplits: 1)
            if pair.count == 2 { result[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        func dimension(_ value: String?) -> Double? {
            guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
            if text.hasSuffix("!important") { text = text.dropLast(10).trimmingCharacters(in: .whitespaces) }
            if text.hasSuffix("px") { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) }
            guard let number = Double(text), number.isFinite, number >= 0 else { return nil }
            return number
        }
        guard let w = dimension(declarations["width"] ?? width), let h = dimension(declarations["height"] ?? height) else { return false }
        return w <= 1 && h <= 1
    }
}
