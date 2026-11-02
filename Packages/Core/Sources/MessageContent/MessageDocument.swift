import Foundation
import SwiftSoup

/// A message ready for a web view: sanitized markup in a page that forbids
/// scripts and every network load.
public struct RenderedMessage: Sendable, Equatable {
    public let html: String
    /// Remote images, stylesheets and other loads that were removed.
    public let blockedRemoteContent: Int
    /// Blocked images that `allowsRemoteImages` would show.
    public var blockedRemoteImages: Int = 0
    public var blockedTrackers: Int = 0
    /// Full visible text, including quoted replies, for conversation-wide Find.
    public var searchableText: String = ""
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
            var trackers = 0
            var hiddenImages = 0
            for element in try document.select("[data-tern-image-state],[data-tern-image-placeholder],[data-tern-image-label],[data-blocked-src]") {
                for attribute in ["data-tern-image-state", "data-tern-image-placeholder", "data-tern-image-label", "data-blocked-src"] {
                    try element.removeAttr(attribute)
                }
            }
            for image in try document.select("img") {
                guard image.hasAttr("src") else { continue }
                let source = try image.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
                if source.lowercased().hasPrefix("cid:") {
                    let cid = String(source.dropFirst(4)).removingPercentEncoding ?? String(source.dropFirst(4))
                    if let url = policy.inlineResources.url(for: cid) { try image.attr("src", url.absoluteString) }
                    else {
                        try image.removeAttr("src")
                        try image.attr("data-tern-image-state", "inline-unavailable")
                    }
                } else if let url = URL(string: source), TrackerMatcher.isTrackingImage(url: url,
                    width: try? image.attr("width"), height: try? image.attr("height"), style: try? image.attr("style")) {
                    // A known tracking image has no reading content or layout to preserve.
                    try image.remove()
                    trackers += 1
                } else if !policy.allowsRemoteImages, let url = URL(string: source), HTMLSanitizer.isConsentLoadable(url) {
                    hiddenImages += 1
                }
            }
            let blocked = try HTMLSanitizer.clean(document, policy: policy)
            for image in try document.select("img:not([src])") {
                let wasBlocked = !(try image.attr("data-blocked-src")).isEmpty
                let missingInline = try image.attr("data-tern-image-state") == "inline-unavailable"
                try describeMissingImage(image, state: wasBlocked ? "blocked" : "unavailable",
                    reason: missingInline ? "Inline image unavailable" : wasBlocked ? "Image blocked" : "Image unavailable")
            }
            guard let head = document.head() else { return render(plainText: html) }
            try head.prepend(headMarkup(style: htmlStyle + "body{font-size:\(13 * policy.textScale)px}", policy: policy))
            document.outputSettings().prettyPrint(pretty: false)
            return RenderedMessage(html: try document.outerHtml(), blockedRemoteContent: blocked,
                blockedRemoteImages: hiddenImages, blockedTrackers: trackers,
                searchableText: try document.body()?.text() ?? "")
        } catch {
            // Showing the escaped source is safe; showing nothing would hide the mail.
            return render(plainText: html)
        }
    }

    /// Keep the image in its original parent so the sender's CSS still applies.
    /// A generated local SVG supplies intrinsic dimensions and readable fallback text.
    private static func describeMissingImage(_ image: Element, state: String, reason: String) throws {
        let originalAlt = try image.attr("alt").trimmingCharacters(in: .whitespacesAndNewlines)
        try image.attr("data-tern-image-state", state)
        if originalAlt.isEmpty {
            try image.attr("alt", reason)
        }
        if try image.attr("title").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try image.attr("title", reason)
        }
        try image.attr("aria-label", originalAlt.isEmpty ? reason : originalAlt + ". " + reason)
        let width = try imageDimension("width", of: image) ?? 300
        let height = try imageDimension("height", of: image) ?? min(120, max(48, width / 2.5))
        let columns = max(8, min(40, Int((min(width, 300) - 16) / 7)))
        let lines = placeholderLines(originalAlt, columns: columns) + placeholderLines(reason, columns: columns)
        let text = lines.enumerated().map { index, line in
            let offset = index == 0 ? -Double(lines.count - 1) * 8 : 16
            return "<tspan x=\"50%\" dy=\"\(offset)\">\(escaped(line))</tspan>"
        }.joined()
        // No viewBox: text uses the displayed viewport's points instead of
        // shrinking with a wide newsletter image in a narrow reader.
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)">
        <style>:root{color-scheme:light}@media(prefers-color-scheme:dark){:root{color-scheme:dark}}
        rect{fill:Canvas;stroke:CanvasText;stroke-opacity:.28;stroke-dasharray:4 3}
        text{fill:CanvasText;font:13px -apple-system,system-ui,sans-serif}</style>
        <rect x="1" y="1" width="calc(100% - 2px)" height="calc(100% - 2px)" rx="6"/>
        <text x="50%" y="50%" text-anchor="middle" dominant-baseline="middle">\(text)</text></svg>
        """
        try image.attr("src", "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString())
    }

    private static func placeholderLines(_ text: String, columns: Int) -> [String] {
        // Bound work and strip XML-invalid control characters before escaping.
        let clean = text.unicodeScalars.prefix(240).filter {
            $0.value >= 0x20 && $0.value != 0xFFFE && $0.value != 0xFFFF
        }.map(String.init).joined()
        guard !clean.isEmpty else { return [] }
        var lines: [String] = []
        var line = ""
        for word in clean.split(whereSeparator: \.isWhitespace) {
            if !line.isEmpty, line.count + word.count + 1 > columns {
                lines.append(line)
                line = ""
            }
            guard lines.count < 2 else { break }
            line += (line.isEmpty ? "" : " ") + String(word.prefix(columns))
        }
        if !line.isEmpty, lines.count < 2 { lines.append(line) }
        return lines
    }

    private static func imageDimension(_ property: String, of image: Element) throws -> Double? {
        func numeric(_ value: String?) -> Double? {
            guard var value else { return nil }
            value = value.lowercased().replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix("px") { value = String(value.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let number = Double(value), number.isFinite, number >= 1, number <= 100_000 else { return nil }
            return number
        }
        let style = try image.attr("style")
        let attribute = try image.attr(property)
        return numeric(inlineDimension(property, in: style)) ?? numeric(attribute)
    }

    private static func inlineDimension(_ property: String, in style: String) -> String? {
        var selected: String?
        for declaration in style.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == property else { continue }
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if selected?.lowercased().contains("!important") != true || value.lowercased().contains("!important") {
                selected = value
            }
        }
        return selected
    }

    public static func render(plainText: String, policy: MessageRenderPolicy = .init()) -> RenderedMessage {
        let page = "<!doctype html><html><head>\(headMarkup(style: plainTextStyle + "body{font-size:\(13 * policy.textScale)px}", policy: policy))</head>"
            + "<body><div class=\"tern-plain\">\(linkified(plainText))</div></body></html>"
        return RenderedMessage(html: page, blockedRemoteContent: 0, searchableText: plainText)
    }

    /// A complete candidate index for Find. WebKit confirms matches against
    /// the displayed document; quoted replies and long bodies stay searchable.
    public static func searchableText(_ body: ExtractedBody) -> String {
        guard let html = body.html else { return body.plainText ?? "" }
        do {
            let document = try SwiftSoup.parse(html)
            try document.select("script,style,head").remove()
            return try document.body()?.text() ?? ""
        } catch { return body.plainText ?? html }
    }

    // The native message card supplies the inset. Type matches the macOS body size (13).

    /// HTML mail is designed for a white page, so the page starts white and
    /// `darkModeScript` adapts its colors in dark mode.
    private static let htmlStyle = """
        :root{color-scheme:light}\
        html{background:#fff;color:#000}\
        body{margin:0;padding:0;font:13px -apple-system,system-ui,sans-serif;overflow-wrap:break-word}\
        img{max-width:100%;height:auto}\
        img[data-tern-image-state]{color-scheme:light dark}
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
