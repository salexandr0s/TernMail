import Foundation
import SwiftSoup

/// Strips active content and remote loads from message HTML.
///
/// This is the first of three layers. The page also carries a strict CSP and
/// the web view applies a content rule list, so anything this misses (CSS
/// escapes, for example) still cannot run or load. The returned count drives
/// the "remote content blocked" notice.
enum HTMLSanitizer {
    private static let removedElements =
        "script, noscript, iframe, frame, frameset, object, embed, applet, meta, link, base, portal, template"
    /// Attributes that fetch a resource as soon as the page renders.
    private static let loadingAttributes: Set<String> = ["src", "srcset", "poster", "background", "lowsrc", "dynsrc"]
    /// Attributes that navigate when used, checked for script URLs.
    private static let linkAttributes: Set<String> = ["href", "xlink:href", "action", "formaction", "cite", "longdesc"]
    private static let svgReferenceElements: Set<String> = ["image", "use", "feimage"]

    /// Cleans `document` in place and returns how many remote loads it removed.
    static func clean(_ document: Document) throws -> Int {
        var blocked = 0
        for element in try document.select(removedElements) {
            if element.tagName() == "link", try !element.attr("href").isEmpty { blocked += 1 }
            try element.remove()
        }
        for form in try document.select("form") {
            try form.unwrap()
        }
        for style in try document.select("style") {
            for node in style.dataNodes() {
                let (css, count) = neutralizeCSS(node.getWholeData())
                if count > 0 { node.setWholeData(css) }
                blocked += count
            }
        }
        for element in try document.getAllElements() {
            blocked += try cleanAttributes(of: element)
        }
        return blocked
    }

    private static func cleanAttributes(of element: Element) throws -> Int {
        guard let attributes = element.getAttributes()?.asList(), !attributes.isEmpty else { return 0 }
        let tag = element.tagName().lowercased()
        var loadsRemote = false

        for attribute in attributes {
            let key = attribute.getKey()
            let name = key.lowercased()
            let value = attribute.getValue()

            if name.hasPrefix("on") || name == "ping" {
                try element.removeAttr(key)
            } else if name == "style" {
                let (css, count) = neutralizeCSS(value)
                if count > 0 {
                    try element.attr(key, css)
                    loadsRemote = true
                }
            } else if loadingAttributes.contains(name)
                || (svgReferenceElements.contains(tag) && (name == "href" || name == "xlink:href")) {
                if name != "srcset", isInline(value) { continue }
                if tag == "img", name == "src" {
                    try element.attr("data-blocked-src", value)
                }
                try element.removeAttr(key)
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { loadsRemote = true }
            } else if linkAttributes.contains(name), isScriptURL(value) {
                try element.removeAttr(key)
            }
        }
        // One element counts once, however many of its attributes pointed off-device.
        return loadsRemote ? 1 : 0
    }

    /// Replaces remote `url()` values with `none` and drops `@import` rules.
    /// Data URLs and fragment references such as SVG `url(#gradient)` stay.
    static func neutralizeCSS(_ css: String) -> (css: String, blocked: Int) {
        let lowered = css.lowercased()
        guard lowered.contains("url(") || lowered.contains("@import") else { return (css, 0) }
        // Regex isn't Sendable, so these can't be shared statics.
        let importRule = #/(?i)@import\s+[^;]*;?/#
        let cssURL = #/(?i)url\(\s*(['"]?)(.*?)\1\s*\)/#
        var blocked = 0
        var result = css.replacing(importRule) { _ in
            blocked += 1
            return ""
        }
        result = result.replacing(cssURL) { match in
            let target = match.output.2.trimmingCharacters(in: .whitespaces).lowercased()
            if target.hasPrefix("data:") || target.hasPrefix("#") { return String(match.output.0) }
            if !target.isEmpty { blocked += 1 }
            return "none"
        }
        return (result, blocked)
    }

    private static func isInline(_ value: String) -> Bool {
        let target = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return target.hasPrefix("data:") || target.hasPrefix("cid:")
    }

    private static func isScriptURL(_ value: String) -> Bool {
        // Browsers ignore whitespace and control characters inside the scheme.
        let scheme = value.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init)
        let target = String(scheme).lowercased()
        return target.hasPrefix("javascript:") || target.hasPrefix("vbscript:") || target.hasPrefix("data:text/html")
    }
}
