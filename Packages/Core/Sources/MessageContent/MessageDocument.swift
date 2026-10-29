import Foundation
import SwiftSoup

/// A message ready for a web view: sanitized markup in a page that forbids
/// scripts and every network load.
public struct RenderedMessage: Sendable, Equatable {
    public let html: String
    /// Remote images, stylesheets and other loads that were removed.
    public let blockedRemoteContent: Int
}

public enum MessageDocument {
    /// Only inline images, inline styles and embedded fonts may load.
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:"

    /// Prefers the HTML part and falls back to plain text.
    public static func render(_ body: ExtractedBody) -> RenderedMessage? {
        if let html = body.html { return render(html: html) }
        if let plainText = body.plainText { return render(plainText: plainText) }
        return nil
    }

    /// Plain text only, for when the web view can't block remote loads itself.
    /// HTML-only mail loses its formatting.
    public static func renderText(_ body: ExtractedBody) -> RenderedMessage? {
        if let plainText = body.plainText { return render(plainText: plainText) }
        guard let html = body.html else { return nil }
        let text = (try? SwiftSoup.parse(html).body()?.text()) ?? nil
        return render(plainText: text ?? html)
    }

    public static func render(html: String) -> RenderedMessage {
        do {
            let document = try SwiftSoup.parse(html)
            let blocked = try HTMLSanitizer.clean(document)
            guard let head = document.head() else { return render(plainText: html) }
            try head.prepend(headMarkup(style: htmlStyle))
            document.outputSettings().prettyPrint(pretty: false)
            return RenderedMessage(html: try document.outerHtml(), blockedRemoteContent: blocked)
        } catch {
            // Showing the escaped source is safe; showing nothing would hide the mail.
            return render(plainText: html)
        }
    }

    public static func render(plainText: String) -> RenderedMessage {
        let page = "<!doctype html><html><head>\(headMarkup(style: plainTextStyle))</head>"
            + "<body><div class=\"tern-plain\">\(linkified(plainText))</div></body></html>"
        return RenderedMessage(html: page, blockedRemoteContent: 0)
    }

    // The values below mirror Tokens.Space.s4 (16) and the macOS body size (13).

    /// HTML mail is designed for a white page, so the page starts white and
    /// `darkModeScript` adapts its colors in dark mode.
    private static let htmlStyle = """
        :root{color-scheme:light}\
        html{background:#fff;color:#000}\
        body{margin:0;padding:16px;font:13px -apple-system,system-ui,sans-serif;overflow-wrap:break-word}\
        img{max-width:100%;height:auto}
        """

    private static let plainTextStyle = """
        :root{color-scheme:light dark}\
        html{background:Canvas;color:CanvasText}\
        body{margin:0;padding:16px;font:13px -apple-system,system-ui,sans-serif}\
        .tern-plain{white-space:pre-wrap;overflow-wrap:anywhere}
        """

    private static func headMarkup(style: String) -> String {
        "<meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
            + "<style>\(style)</style>"
    }

    /// Escapes plain text and turns web and mail addresses into links.
    static func linkified(_ text: String) -> String {
        let source = text as NSString
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return escaped(text)
        }
        var output = ""
        var cursor = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme)
            else { continue }
            output += escaped(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            output += "<a href=\"\(escaped(url.absoluteString))\">\(escaped(source.substring(with: match.range)))</a>"
            cursor = NSMaxRange(match.range)
        }
        output += escaped(source.substring(from: cursor))
        return output
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

public enum HTMLEntities {
    /// Gmail snippets arrive with entities such as `&#39;` and `&amp;`.
    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return (try? Entities.unescape(text)) ?? text
    }
}
