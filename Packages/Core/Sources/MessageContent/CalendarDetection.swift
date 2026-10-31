import Foundation
import SwiftSoup

/// A date found in a message is a candidate for review, not a confirmed meeting.
public struct DetectedCalendarSuggestion: Codable, Sendable, Equatable, Identifiable {
    /// `timeZoneMissing` means the text gives a time without a zone. That only
    /// matters when the sender is elsewhere (`senderClockDifference`).
    public enum Uncertainty: String, Codable, Sendable {
        case dateNeedsReview, timeNeedsReview, timeZoneMissing, durationMissing
    }

    public var id: String
    public var sourceText: String
    public var sourceLocation: Int
    public var sourceLength: Int
    public var start: Date
    public var end: Date?
    public var isAllDay: Bool
    public var timeZoneID: String
    public var uncertainties: [Uncertainty]

    public init(id: String, sourceText: String, sourceLocation: Int, sourceLength: Int,
                start: Date, end: Date?, isAllDay: Bool, timeZoneID: String,
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
    /// Every date resolves against the message date, never the day on which the
    /// message happens to be opened. A mention becomes a suggestion only when it
    /// names an upcoming day: times, durations, opening hours, deadlines and past
    /// days are left out, so every suggestion has a date.
    public static func suggestions(in text: String, messageDate: Date,
                                   timeZone: TimeZone = .autoupdatingCurrent,
                                   locale: Locale = .autoupdatingCurrent) -> [DetectedCalendarSuggestion] {
        guard text.utf16.count <= maximumTextLength,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let visible = unquotedText(text) as NSString
        var mentions: [DateMention] = []
        for match in detector.matches(in: visible as String, range: NSRange(location: 0, length: visible.length)) {
            guard let mention = DateMention(match, in: visible, locale: locale) else { continue }
            if mention.day != nil {
                mentions.append(mention)
            } else if let last = mentions.indices.last, mentions[last].canTakeTime(from: mention, in: visible) {
                mentions[last].join(mention)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        var results: [DetectedCalendarSuggestion] = []
        for mention in mentions {
            guard let range = Range(mention.range, in: text),
                  let suggestion = mention.suggestion(source: String(text[range]), messageDate: messageDate, calendar: calendar),
                  !results.contains(where: { $0.start == suggestion.start && $0.end == suggestion.end }) else { continue }
            results.append(suggestion)
        }
        // A bare date adds nothing when a timed mention names the same day.
        let timedStarts = results.filter { !$0.isAllDay }.map(\.start)
        results.removeAll { candidate in
            candidate.isAllDay && candidate.end.map { calendar.dateComponents([.day], from: candidate.start, to: $0).day == 1 } != false
                && timedStarts.contains { calendar.isDate($0, inSameDayAs: candidate.start) }
        }
        return Array(results.prefix(maximumSuggestions))
    }

    /// How many seconds the sender's clock ran ahead of the reader's when the
    /// message was sent, from the Date header's UTC offset. Nil when the two
    /// agree or the header tells nothing: mail servers and bulk senders often
    /// write +0000 whatever zone their events are in.
    public static func senderClockDifference(dateHeaderOffset: Int?, sentAt date: Date, readerTimeZone: TimeZone) -> Int? {
        guard let dateHeaderOffset, dateHeaderOffset != 0 else { return nil }
        let difference = dateHeaderOffset - readerTimeZone.secondsFromGMT(for: date)
        return difference == 0 ? nil : difference
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
}
