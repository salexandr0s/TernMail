import Foundation
import SwiftSoup

/// A separate evidence channel for an explicitly forwarded message. Local date
/// detection continues to use quotation-free text.
public enum CalendarForwardedText {
    private static let quoteStart = "TERN_CALENDAR_FORWARD_QUOTE_START_8C31"
    private static let quoteEnd = "TERN_CALENDAR_FORWARD_QUOTE_END_8C31"

    public static func extract(html: String?, plainText: String?) -> String? {
        let readable: String
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard plainText.utf16.count <= CalendarDetection.maximumTextLength else { return nil }
            readable = plainText
        } else {
            guard let html, html.utf8.count <= CalendarDetection.maximumTextLength * 8,
                  html.range(of: "forwarded", options: .caseInsensitive) != nil else { return nil }
            do {
                let document = try SwiftSoup.parse(html)
                try document.select("script,style,head,template,noscript,[hidden],[aria-hidden=true],.gmail_signature,.moz-signature").remove()
                for element in try document.select("[style]").array() {
                    let style = try element.attr("style").lowercased().filter { !$0.isWhitespace }
                    if style.contains("display:none") || style.contains("visibility:hidden") { try element.remove() }
                }
                for quote in try document.select("blockquote,.gmail_quote,.yahoo_quoted,.protonmail_quote,[type=cite]").array() {
                    try quote.before("<p>\n\(quoteStart)\n</p>")
                    try quote.after("<p>\n\(quoteEnd)\n</p>")
                }
                for node in try document.select("br,p,div,li,tr,section").array() { try node.appendText("\n") }
                readable = try document.body()?.text(trimAndNormaliseWhitespace: false) ?? ""
            } catch { return nil }
        }
        guard readable.utf16.count <= CalendarDetection.maximumTextLength else { return nil }
        return body(in: readable)
    }

    /// Forwarded dates must supply their own year. Neither the forwarding date
    /// nor the day on which the message is opened can complete them.
    public static func containsExplicitDay(_ day: String, in text: String,
                                          locale: Locale = .autoupdatingCurrent) -> Bool {
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              text.utf16.count <= CalendarDetection.maximumTextLength,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return false }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == parts[0], check.month == parts[1], check.day == parts[2] else { return false }
        let source = CalendarDetection.unquotedText(text) as NSString
        return detector.matches(in: source as String, range: NSRange(location: 0, length: source.length)).contains { match in
            let written = source.substring(with: match.range)
            let standalone = match.adjustingRanges(offset: -match.range.location)
            guard let mention = DateMention(standalone, in: written as NSString, locale: locale),
                  case .date(let year?, let month, let day, let ambiguous) = mention.day else { return false }
            let hasFullYear = written.range(of: "(?<!\\d)\(String(format: "%04d", year))(?!\\d)", options: .regularExpression) != nil
            return hasFullYear && !ambiguous && year == parts[0] && month == parts[1] && day == parts[2]
        }
    }

    private static func body(in text: String) -> String? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var marker: Int?
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if isForwardMarker(line) { marker = index; break }
            if line == quoteStart {
                // Gmail puts the forwarding marker inside its quotation wrapper.
                let next = lines.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard let next, isForwardMarker(next.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            } else if isReplyOrSignature(line) || line == quoteEnd { return nil }
        }
        guard let marker else { return nil }
        var headers = Set<String>()
        var bodyStart: Int?
        for index in (marker + 1)..<min(lines.count, marker + 25) {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == quoteStart || line == quoteEnd { return nil }
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if ["from", "date", "sent", "to", "cc", "bcc", "subject", "reply-to"].contains(key), !value.isEmpty {
                    headers.insert(key)
                    continue
                }
            }
            guard headers.contains("from"), headers.contains("subject"),
                  !headers.isDisjoint(with: ["date", "sent"]) else { return nil }
            bodyStart = index
            break
        }
        guard let bodyStart else { return nil }
        var body: [String] = []
        for raw in lines.dropFirst(bodyStart) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == quoteStart || line == quoteEnd || isForwardMarker(line) || isReplyOrSignature(line) { break }
            body.append(raw)
        }
        let result = CalendarDetection.unquotedText(body.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func isForwardMarker(_ line: String) -> Bool {
        line.range(of: #"^(?:-{2,}\s*forwarded message\s*-{2,}|begin forwarded message:)\s*$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isReplyOrSignature(_ line: String) -> Bool {
        let lower = line.lowercased()
        return line.hasPrefix(">") || line == "--" || lower.hasPrefix("sent from my ")
            || lower.hasPrefix("von meinem ") || (lower.hasPrefix("on ") && lower.hasSuffix("wrote:"))
            || (lower.hasPrefix("am ") && lower.contains("schrieb") && lower.hasSuffix(":"))
            || lower.contains("original message") || lower.contains("ursprüngliche nachricht")
    }
}
