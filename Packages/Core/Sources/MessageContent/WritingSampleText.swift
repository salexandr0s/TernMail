import Foundation
import SwiftSoup

/// Keeps authored prose and its paragraph breaks while discarding common reply,
/// forwarding, and signature material. This is a heuristic, not anonymization.
public enum WritingSampleText {
    public struct Result: Sendable, Equatable {
        public let text: String
        public let truncated: Bool
        public let isUsable: Bool
    }

    public static let maximumInputBytes = 131_072

    public static func extract(html: String?, plainText: String?, maximumBytes: Int = 2_048) -> Result {
        var truncated = false
        let readable: String
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            truncated = plainText.utf8.count > maximumInputBytes
            readable = String(decoding: plainText.utf8.prefix(maximumInputBytes), as: UTF8.self)
        } else if let html {
            guard html.utf8.count <= maximumInputBytes else { return Result(text: "", truncated: true, isUsable: false) }
            do {
                let document = try SwiftSoup.parse(html)
                for marker in try document.select("#divRplyFwdMsg,.gmail_attr,.moz-cite-prefix").array() {
                    try marker.before("<p>----- Original Message -----</p>")
                }
                try document.select("script,style,head,blockquote,.gmail_quote,.yahoo_quoted,.protonmail_quote,[type=cite],.gmail_signature,.moz-signature").remove()
                // DOM text omits list markers. Preserve that formatting evidence
                // before discarding HTML, with each nested list on its own line.
                for list in try document.select("ul,ol").array() {
                    let ordered = list.tagName() == "ol"
                    var number = Int(try list.attr("start")) ?? 1
                    for item in list.children().array() where item.tagName() == "li" {
                        if ordered { number = Int(try item.attr("value")) ?? number }
                        try item.prependText(ordered ? "\(number). " : "• ")
                        if number < Int.max { number += 1 }
                    }
                    try list.prependText("\n")
                    try list.appendText("\n")
                }
                for node in try document.select("br,p,div,li,tr,section,h1,h2,h3,h4,h5,h6").array() { try node.appendText("\n") }
                readable = try document.body()?.text(trimAndNormaliseWhitespace: false) ?? ""
            } catch { return Result(text: "", truncated: true, isUsable: false) }
        } else { return Result(text: "", truncated: false, isUsable: false) }

        let lines = readable.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var kept: [String] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            let attribution = lines[index..<min(lines.count, index + 3)].joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if line == "--" || lower.hasPrefix("sent from my ") || lower.hasPrefix("von meinem ")
                || lower.hasPrefix("get outlook for ") || lower.hasPrefix("this email and any attachments are confidential")
                || lower.contains("begin forwarded message") || lower.contains("forwarded message")
                || lower.contains("original message") || lower.contains("ursprüngliche nachricht")
                || ((lower.hasPrefix("on ") || lower.hasPrefix("am "))
                    && (attribution.contains("wrote:") || attribution.contains("schrieb"))) { break }
            if matches(#"^(?:from|von):\s"#, line),
               matches(#"(?m)^(?:to|an|sent|gesendet|subject|betreff):\s"#, lines[index..<min(lines.count, index + 6)].joined(separator: "\n")) { break }
            if line.hasPrefix(">") { continue }
            if line.isEmpty {
                if kept.last?.isEmpty == false { kept.append("") }
                continue
            }
            kept.append(line.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression))
            // Retain the closing phrase as style evidence, but not its name,
            // job title, telephone number, or repeated business footer.
            if !kept.dropLast().allSatisfy(\.isEmpty), matches(#"^(?:best(?: regards)?|kind regards|regards|thanks|thank you|many thanks|cheers|sincerely|yours(?: sincerely)?|liebe grüße|viele grüße|beste grüße|mit freundlichen grüßen|lg|vg)[,!\.]*$"#, line) { break }
        }
        var text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        text = replacing(#"(?i)\b(?:https?://|www\.)[^\s<>]+"#, in: text, with: "[link]")
        text = replacing(#"(?i)[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}"#, in: text, with: "[email]")
        text = replacing(#"(?<![\p{L}\d])\+?\d[\d ()/.-]{5,}\d(?![\p{L}\d])"#, in: text, with: "[number]")
        let cap = max(0, maximumBytes)
        truncated = truncated || text.utf8.count > cap
        var bytes = Array(text.utf8.prefix(cap))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        text = String(decoding: bytes, as: UTF8.self)
        let prose = text.replacingOccurrences(of: #"\[(?:link|email|number)\]"#, with: "", options: .regularExpression)
        return Result(text: text, truncated: truncated, isUsable: prose.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 8)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func replacing(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
