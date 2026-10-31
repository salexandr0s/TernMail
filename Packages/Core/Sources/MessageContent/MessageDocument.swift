import Foundation
import SwiftSoup

/// A message ready for a web view: sanitized markup in a page that forbids
/// scripts and every network load.
public struct RenderedMessage: Sendable, Equatable {
    public let html: String
    /// Remote images, stylesheets and other loads that were removed.
    public let blockedRemoteContent: Int
    public var blockedTrackers: Int = 0
    public var hasAuthoredDarkStyles: Bool = false
}

public enum MessageDocument {
    /// Only inline images, inline styles and embedded fonts may load.
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src data: tern-message:; style-src 'unsafe-inline'; font-src data:"

    /// Prefers the HTML part and falls back to plain text.
    public static func render(_ body: ExtractedBody, policy: MessageRenderPolicy = .init()) -> RenderedMessage? {
        if let html = body.html { return render(html: html, policy: policy) }
        if let plainText = body.plainText { return render(plainText: plainText, policy: policy) }
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

    public static func render(html: String, policy: MessageRenderPolicy = .init()) -> RenderedMessage {
        do {
            let document = try SwiftSoup.parse(html)
            let authoredDark = try document.select("style").contains { $0.data().lowercased().contains("prefers-color-scheme") }
            var trackers = 0
            for image in try document.select("img[src]") {
                let source = try image.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
                if source.lowercased().hasPrefix("cid:") {
                    let cid = String(source.dropFirst(4)).removingPercentEncoding ?? String(source.dropFirst(4))
                    if let url = policy.inlineResources.url(for: cid) { try image.attr("src", url.absoluteString) }
                    else { try image.removeAttr("src") }
                } else if let url = URL(string: source), TrackerMatcher.isTrackingImage(url: url,
                    width: try? image.attr("width"), height: try? image.attr("height"), style: try? image.attr("style")) {
                    try image.removeAttr("src")
                    try image.removeAttr("srcset")
                    trackers += 1
                }
            }
            let blocked = try HTMLSanitizer.clean(document, policy: policy)
            guard let head = document.head() else { return render(plainText: html) }
            try head.prepend(headMarkup(style: htmlStyle + "body{font-size:\(13 * policy.textScale)px}", policy: policy))
            document.outputSettings().prettyPrint(pretty: false)
            return RenderedMessage(html: try document.outerHtml(), blockedRemoteContent: blocked,
                blockedTrackers: trackers, hasAuthoredDarkStyles: authoredDark)
        } catch {
            // Showing the escaped source is safe; showing nothing would hide the mail.
            return render(plainText: html)
        }
    }

    public static func render(plainText: String, policy: MessageRenderPolicy = .init()) -> RenderedMessage {
        let page = "<!doctype html><html><head>\(headMarkup(style: plainTextStyle + "body{font-size:\(13 * policy.textScale)px}", policy: policy))</head>"
            + "<body><div class=\"tern-plain\">\(linkified(plainText))</div></body></html>"
        return RenderedMessage(html: page, blockedRemoteContent: 0)
    }

    // The native message card supplies the inset. Type matches the macOS body size (13).

    /// HTML mail is designed for a white page, so the page starts white and
    /// `darkModeScript` adapts its colors in dark mode.
    private static let htmlStyle = """
        :root{color-scheme:light}\
        html{background:#fff;color:#000}\
        body{margin:0;padding:0;font:13px -apple-system,system-ui,sans-serif;overflow-wrap:break-word}\
        img{max-width:100%;height:auto}
        """

    private static let plainTextStyle = """
        :root{color-scheme:light dark}\
        html{background:Canvas;color:CanvasText}\
        body{margin:0;padding:0;font:13px -apple-system,system-ui,sans-serif}\
        .tern-plain{white-space:pre-wrap;overflow-wrap:anywhere}
        """

    private static func headMarkup(style: String, policy: MessageRenderPolicy = .init()) -> String {
        "<meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy.contentSecurityPolicy)\">"
            + "<style>\(style)</style>"
    }

    /// Escapes plain text and turns web and mail addresses into links.
    static func linkified(_ text: String) -> String {
        linkedRuns(text).map { run in
            guard let link = run.link else { return escaped(run.text) }
            return "<a href=\"\(escaped(link.absoluteString))\">\(escaped(run.text))</a>"
        }.joined()
    }

    /// Plain text as compose runs, with a link on each web or mail address in it.
    static func linkedRuns(_ text: String) -> [ComposeDocument.Run] {
        let source = text as NSString
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return [ComposeDocument.Run(text)]
        }
        var runs: [ComposeDocument.Run] = []
        var cursor = 0
        for match in detector.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let link = ComposeDocument.safeLink(match.url) else { continue }
            if match.range.location > cursor {
                runs.append(ComposeDocument.Run(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            runs.append(ComposeDocument.Run(source.substring(with: match.range), link: link))
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length { runs.append(ComposeDocument.Run(source.substring(from: cursor))) }
        return runs
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
