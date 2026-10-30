import Foundation
import SwiftSoup

/// A date found in a message is a candidate for review, not a confirmed meeting.
public struct DetectedCalendarSuggestion: Codable, Sendable, Equatable, Identifiable {
    public enum Uncertainty: String, Codable, Sendable {
        case dateNeedsReview, timeNeedsReview, timeZoneMissing, durationMissing
    }

    public var id: String
    public var sourceText: String
    public var sourceLocation: Int
    public var sourceLength: Int
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool
    public var timeZoneID: String
    public var uncertainties: [Uncertainty]

    public init(id: String, sourceText: String, sourceLocation: Int, sourceLength: Int,
                start: Date?, end: Date?, isAllDay: Bool, timeZoneID: String,
                uncertainties: [Uncertainty]) {
        self.id = id; self.sourceText = sourceText
        self.sourceLocation = sourceLocation; self.sourceLength = sourceLength
        self.start = start; self.end = end; self.isAllDay = isAllDay
        self.timeZoneID = timeZoneID; self.uncertainties = uncertainties
    }
}

public enum CalendarDetection {
    public static let maximumTextLength = 200_000
    public static let maximumSuggestions = 20

    /// Readable message text with HTML quotation containers removed. Keeping line
    /// breaks lets the plain-text quotation and signature checks still apply.
    public static func readableText(html: String?, plainText: String?) -> String {
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plainText
        }
        guard let html, html.utf8.count <= maximumTextLength * 8 else { return "" }
        do {
            let document = try SwiftSoup.parse(html)
            try document.select("script,style,head,blockquote,.gmail_quote,.yahoo_quoted,.protonmail_quote,[type=cite],.gmail_signature").remove()
            for node in try document.select("br,p,div,li,tr").array() { try node.appendText("\n") }
            return try document.body()?.text(trimAndNormaliseWhitespace: false) ?? ""
        } catch {
            // Falling back to raw HTML would interpret dates in hidden content.
            return ""
        }
    }

    /// Ranges refer to the supplied text in UTF-16 units, as NSTextCheckingResult does.
    /// Relative dates never use the day on which the message happens to be opened.
    public static func suggestions(in text: String, messageDate: Date,
                                   timeZone: TimeZone = .autoupdatingCurrent,
                                   locale: Locale = .autoupdatingCurrent) -> [DetectedCalendarSuggestion] {
        guard text.utf16.count <= maximumTextLength,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let visible = unquotedText(text)
        let matches = detector.matches(in: visible, range: NSRange(visible.startIndex..., in: visible))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale

        return matches.prefix(maximumSuggestions).compactMap { match in
            guard let range = Range(match.range, in: text), let detected = match.date else { return nil }
            let source = String(text[range])
            let lower = source.lowercased(with: locale)
            let hasTime = matchesPattern(#"\d{1,2}:\d{2}|\b\d{1,2}\s*(?:am|pm|a\.m\.|p\.m\.|uhr)\b|\b(?:noon|midnight|mittag|mitternacht)\b"#, lower)
            let hasYear = matchesPattern(#"\b(?:19|20|21)\d{2}\b"#, lower)
            let relativeOffset = relativeDayOffset(in: lower)
            let hasRelative = relativeOffset != nil || matchesPattern(#"\b(?:next|last|this|monday|tuesday|wednesday|thursday|friday|saturday|sunday|montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|nächste|kommende)\b"#, lower)
            var uncertainty: [DetectedCalendarSuggestion.Uncertainty] = []
            let effectiveZone = match.timeZone ?? timeZone
            var detectorCalendar = calendar
            detectorCalendar.timeZone = match.timeZone ?? .autoupdatingCurrent
            var targetCalendar = calendar
            targetCalendar.timeZone = effectiveZone
            // The detector interprets unqualified clock times in the Mac's zone.
            // Rebuild their wall-clock components in the user's chosen zone.
            var result: Date? = match.timeZone == nil
                ? targetCalendar.date(from: detectorCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: detected))
                : detected
            if let offset = relativeOffset {
                var referenceCalendar = calendar
                referenceCalendar.timeZone = effectiveZone
                if let day = referenceCalendar.date(byAdding: .day, value: offset, to: referenceCalendar.startOfDay(for: messageDate)) {
                    let time = detectorCalendar.dateComponents([.hour, .minute, .second], from: detected)
                    result = hasTime
                        ? referenceCalendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
                        : day
                } else { result = nil }
            } else if !hasYear || hasRelative {
                // NSDataDetector does not expose its reference date. An incomplete
                // date from old mail therefore needs review rather than a guessed year.
                result = nil
                uncertainty.append(.dateNeedsReview)
            }
            if !hasTime, matchesPattern(#"\b(?:at|um)\s+\d{1,2}\b"#, lower) {
                uncertainty.append(.timeNeedsReview)
            }
            let isAllDay = !hasTime && !uncertainty.contains(.timeNeedsReview)
            if hasTime, match.timeZone == nil { uncertainty.append(.timeZoneMissing) }
            let end: Date?
            if match.duration > 0, let result {
                end = result.addingTimeInterval(match.duration)
            } else if isAllDay, let result {
                end = calendar.date(byAdding: .day, value: 1, to: result)
            } else {
                end = nil
                uncertainty.append(.durationMissing)
            }
            return DetectedCalendarSuggestion(
                id: "\(match.range.location):\(match.range.length):\(source)", sourceText: source,
                sourceLocation: match.range.location, sourceLength: match.range.length,
                start: result, end: end, isAllDay: isAllDay,
                timeZoneID: effectiveZone.identifier, uncertainties: uncertainty
            )
        }
    }

    /// Masking keeps source offsets stable while excluding common quotation and
    /// signature forms. The caller supplies plain, rendered text, never raw HTML.
    public static func unquotedText(_ text: String) -> String {
        let string = text as NSString
        let output = NSMutableString(string: text)
        var offset = 0
        var stop = false
        while offset < string.length {
            let lineRange = string.lineRange(for: NSRange(location: offset, length: 0))
            let line = string.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if line == "--" || lower.hasPrefix("sent from my ") || lower.hasPrefix("von meinem ")
                || lower.contains("begin forwarded message") || lower.contains("forwarded message")
                || lower.contains("original message") || lower.contains("ursprüngliche nachricht")
                || (lower.hasPrefix("on ") && lower.hasSuffix("wrote:"))
                || (lower.hasPrefix("am ") && lower.contains("schrieb") && lower.hasSuffix(":")) {
                stop = true
            }
            if stop || line.hasPrefix(">") {
                output.replaceCharacters(in: lineRange, with: String(repeating: " ", count: lineRange.length))
            }
            offset = NSMaxRange(lineRange)
        }
        return output as String
    }

    private static func matchesPattern(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func relativeDayOffset(in text: String) -> Int? {
        for (pattern, offset) in [
            (#"\b(?:day after tomorrow|übermorgen)\b"#, 2),
            (#"\b(?:tomorrow|morgen)\b"#, 1),
            (#"\b(?:today|heute)\b"#, 0),
            (#"\b(?:yesterday|gestern)\b"#, -1),
        ] where matchesPattern(pattern, text) { return offset }
        return nil
    }
}
