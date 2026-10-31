import Foundation

/// One NSDataDetector date match, read for the day it names. The detector also
/// matches bare times, durations, opening hours and deadlines, and it fills in a
/// missing year or weekday from today rather than from the message date, so its
/// date alone cannot tell an event from a passing mention.
struct DateMention {
    enum Day: Equatable {
        case date(year: Int?, month: Int, day: Int, isAmbiguous: Bool)
        case relative(days: Int)
        case weekday(Int, isNext: Bool)
    }

    private(set) var range: NSRange
    /// Nil for a time or duration that names no day.
    let day: Day?
    /// The calendar weekday (1 is Sunday) when the mention names exactly one.
    let weekday: Int?
    private(set) var hasTime: Bool
    private(set) var timeNeedsReview: Bool
    /// The wall-clock time as written. The detector reads an unqualified time in
    /// the Mac's zone; resolution rebuilds it in the user's chosen zone.
    private(set) var clock: DateComponents
    private(set) var duration: TimeInterval
    private(set) var timeZone: TimeZone?

    var hasClock: Bool { hasTime || timeNeedsReview }

    init?(_ match: NSTextCheckingResult, in text: NSString, locale: Locale) {
        guard let date = match.date else { return nil }
        let source = text.substring(with: match.range).lowercased(with: locale)
        var detectorCalendar = Calendar(identifier: .gregorian)
        detectorCalendar.timeZone = match.timeZone ?? .autoupdatingCurrent
        let detected = detectorCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        // Times come out first, so the 3 in "July at 3pm" is no day of July.
        let foundTime = Self.time.matches(source)
        let dateText = foundTime ? Self.time.blanking(source) : source
        let numeric = Self.numericDate(in: dateText, locale: locale)
        let hasTime = foundTime || numeric == nil && Self.isBareTime(in: dateText, hour: detected.hour, minute: detected.minute)
        let words = Self.words(in: dateText)
        let weekdays = Set(words.compactMap { Self.vocabulary.weekdays[$0] })
        range = match.range
        weekday = weekdays.count == 1 ? weekdays.first : nil
        self.hasTime = hasTime
        timeNeedsReview = !hasTime && Self.vagueTime.matches(source)
        clock = DateComponents(hour: detected.hour, minute: detected.minute, second: detected.second)
        duration = Self.inventsDuration(source) ? 0 : match.duration
        timeZone = match.timeZone

        if let numeric {
            // "24/7" has no year, time or weekday that would make it a day.
            guard numeric.year != nil || hasTime || weekday != nil else { return nil }
            day = .date(year: numeric.year, month: numeric.month, day: numeric.day, isAmbiguous: numeric.isAmbiguous)
        } else if words.contains(where: Self.vocabulary.months.contains), Self.dayNumber.matches(dateText),
                  let month = detected.month, let dayOfMonth = detected.day {
            day = .date(year: Self.yearNumber.matches(dateText) ? detected.year : nil, month: month, day: dayOfMonth, isAmbiguous: false)
        } else if let offset = Self.relativeDays.first(where: { $0.pattern.matches(source) })?.days {
            day = .relative(days: offset)
        } else if let weekday {
            day = .weekday(weekday, isNext: Self.nextQualifier.matches(source))
        } else {
            // A time alone can still complete the date written just before it.
            guard hasTime else { return nil }
            if let written = Self.writtenClock(in: source) {
                clock = written.clock
                timeNeedsReview = written.isAmbiguous
            }
            day = nil
            return
        }
        let before = Self.sentence(before: match.range, in: text).lowercased(with: locale)
        let after = Self.sentence(after: match.range, in: text).lowercased(with: locale)
        guard !Self.isDeadline(source, before: before, after: after) else { return nil }
        if case .date = day { return }
        // Two weekdays ("Monday–Friday") are opening hours, and "every" or "last"
        // makes a weekday recurring or past.
        let tail = String(before.suffix(16))
        let nearby = weekdays.union(Self.words(in: tail).compactMap { Self.vocabulary.weekdays[$0] })
        guard nearby.count < 2, !Self.qualifiesWeekday(in: tail + source + after) else { return nil }
    }

    /// A time written just after a date, with only a connector between them as in
    /// "Saturday, July 15\nTime: 7pm", completes that date.
    func canTakeTime(from other: DateMention, in text: NSString) -> Bool {
        let start = NSMaxRange(range), length = other.range.location - start
        guard day != nil, !hasClock, other.day == nil, other.hasTime, (0...24).contains(length) else { return false }
        let gap = text.substring(with: NSRange(location: start, length: length)).lowercased()
        return gap.split(whereSeparator: { !$0.isLetter }).allSatisfy { Self.connectors.contains(String($0)) }
    }

    mutating func join(_ other: DateMention) {
        range = NSUnionRange(range, other.range)
        hasTime = true
        timeNeedsReview = other.timeNeedsReview
        clock = other.clock
        duration = other.duration
        timeZone = other.timeZone
    }

    /// Resolves the day against the message date. Days before the message, a lone
    /// date on the day it was sent, and weekdays or relative days without a time
    /// ("Happy Friday", "I'll send it tomorrow") give no suggestion.
    func suggestion(source: String, messageDate: Date, calendar base: Calendar) -> DetectedCalendarSuggestion? {
        guard let day else { return nil }
        var calendar = base
        if hasTime, let timeZone { calendar.timeZone = timeZone }
        let messageDay = calendar.startOfDay(for: messageDate)
        var uncertainties: [DetectedCalendarSuggestion.Uncertainty] = []
        let date: Date
        switch day {
        case .date(let year, let month, let dayOfMonth, let isAmbiguous):
            guard let resolved = Self.resolve(year: year, month: month, day: dayOfMonth, from: messageDay, in: calendar) else { return nil }
            let weekdayAgrees = weekday.map { $0 == calendar.component(.weekday, from: resolved) }
            if weekdayAgrees == false || isAmbiguous && weekdayAgrees != true { uncertainties.append(.dateNeedsReview) }
            date = resolved
        case .relative(let days):
            guard hasClock, let resolved = calendar.date(byAdding: .day, value: days, to: messageDay) else { return nil }
            if let weekday, weekday != calendar.component(.weekday, from: resolved) {
                guard let named = Self.next(weekday, after: messageDay, in: calendar) else { return nil }
                uncertainties.append(.dateNeedsReview)
                date = named
            } else {
                date = resolved
            }
        case .weekday(let index, let isNext):
            // "Next Friday" may mean the coming Friday or the one after it.
            guard hasClock, let resolved = Self.next(index, after: messageDay, in: calendar) else { return nil }
            if isNext { uncertainties.append(.dateNeedsReview) }
            date = resolved
        }
        guard date >= messageDay, duration <= 31 * 86_400 else { return nil }
        let start: Date
        let end: Date?
        if hasClock {
            guard let value = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0,
                                            second: clock.second ?? 0, of: date) else { return nil }
            start = value
            end = duration > 0 ? value.addingTimeInterval(duration) : nil
            guard (end ?? start) >= messageDate else { return nil }
        } else {
            let days = Int((duration / 86_400).rounded())
            guard days > 0 || date > messageDay,
                  let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) else { return nil }
            start = noon
            end = calendar.date(byAdding: .day, value: days + 1, to: noon)
        }
        if timeNeedsReview { uncertainties.append(.timeNeedsReview) }
        if hasTime, timeZone == nil { uncertainties.append(.timeZoneMissing) }
        if hasClock, end == nil { uncertainties.append(.durationMissing) }
        return DetectedCalendarSuggestion(
            id: "\(range.location):\(range.length):\(source)", sourceText: source,
            sourceLocation: range.location, sourceLength: range.length,
            start: start, end: end, isAllDay: !hasClock,
            timeZoneID: calendar.timeZone.identifier, uncertainties: uncertainties
        )
    }

    // MARK: - Resolution

    private static func resolve(year: Int?, month: Int, day: Int, from messageDay: Date, in calendar: Calendar) -> Date? {
        func civil(_ year: Int) -> Date? {
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            let check = calendar.dateComponents([.year, .month, .day], from: date)
            return check.year == year && check.month == month && check.day == day ? date : nil
        }
        if let year { return civil(year) }
        // A date without a year is the next one on or after the message day. One
        // most of a year ahead is more likely a recent day that has passed.
        let messageYear = calendar.component(.year, from: messageDay)
        guard let date = [messageYear, messageYear + 1].lazy.compactMap(civil).first(where: { $0 >= messageDay }),
              let days = calendar.dateComponents([.day], from: messageDay, to: date).day, days <= 270 else { return nil }
        return date
    }

    /// The first such weekday after the message day, never the message day itself.
    private static func next(_ weekday: Int, after messageDay: Date, in calendar: Calendar) -> Date? {
        let days = (weekday - calendar.component(.weekday, from: messageDay) + 6) % 7 + 1
        return calendar.date(byAdding: .day, value: days, to: messageDay)
    }

    // MARK: - Reading the match

    private static let time = Pattern([
        #"(?<![\d.:/])\d{1,2}h\d{2}(?!\d)"#,
        #"(?<![\d.:/])\d{1,2}(?:[:.]\d{2})?\s*(?:am|pm|a\.m\.|p\.m\.)(?![a-z])"#,
        #"(?<![\d.:/])\d{1,2}:\d{2}(?::\d{2})?(?!\d)"#,
        #"(?<![\d.:/])\d{1,2}(?:[:.]\d{2})?\s*(?:uhr|h)(?![a-z])"#,
        #"\b(?:noon|midnight|mittag|mitternacht|midi|minuit)\b"#,
    ].joined(separator: "|"))
    private static let meridiem = Pattern(#"\d\s*(?:am|pm|a\.m\.|p\.m\.)(?![a-z])"#)
    private static let clockParts = Pattern(#"(?<![\d.:/])(\d{1,2})(?:([:.h])(\d{2}))?(\s*(?:uhr|h)(?![a-z]))?"#)
    private static let bareTime = Pattern(#"(?<![\d.:/])(\d{1,2})\.(\d{2})(?![\d.])"#)
    /// "at 7" or "lunch on Friday" give a time the reader should still check.
    private static let vagueTime = Pattern(#"\b(?:at|um|à|alle|ore)\s+\d{1,2}(?:[.:]\d{2})?(?!\d)|\b(?:breakfast|brunch|lunch|dinner|supper|frühstück|mittagessen|abendessen|déjeuner|dîner|desayuno|almuerzo|cena|colazione|pranzo)\b"#)
    private static let startWord = Pattern(#"\b(?:start(?:s|ing)?|begin(?:s|ning)?)\b"#)
    private static let writtenEnd = Pattern(#"\d\s*[-–—]|[-–—]\s*\d|\s[-–—]\s|\b(?:to|until|till|through|thru|between)\b"#)
    private static let isoDate = Pattern(#"(?<![\d.:/])(\d{4})-(\d{1,2})-(\d{1,2})(?!\d)"#)
    private static let shortDate = Pattern(#"(?<![\d.:/])(\d{1,2})([./-])(\d{1,2})(?:\2(\d{4}|\d{2}))?(?![\d:/-])"#)
    private static let dayNumber = Pattern(#"(?<!\d)\d{1,2}(?!\d)"#)
    private static let yearNumber = Pattern(#"(?<!\d)(?:19|20|21)\d{2}(?!\d)"#)
    private static let nextQualifier = Pattern(#"\b(?:next|nächste[nmrs]?|kommende[nmrs]?|prochaine?|próximo|prossimo)\b"#)
    /// Longer phrases first: "heute Morgen" is this morning, not tomorrow.
    private static let relativeDays: [(pattern: Pattern, days: Int)] = [
        (Pattern(#"\b(?:day after tomorrow|übermorgen|après-demain|pasado mañana|dopodomani)\b"#), 2),
        (Pattern(#"\b(?:today|tonight|this (?:morning|afternoon|evening)|heute|aujourd['’]hui|ce soir|hoy|esta (?:mañana|tarde|noche)|oggi|stasera|stamattina)\b"#), 0),
        (Pattern(#"\b(?:yesterday|gestern|hier|ayer|ieri)\b"#), -1),
        (Pattern(#"\b(?:tomorrow|morgen|demain|mañana|domani)\b"#), 1),
    ]

    private static let connectors: Set<String> = [
        "at", "um", "à", "a", "from", "von", "ab", "de", "dès", "alle", "las", "on", "am", "le", "la", "the",
        "start", "starts", "starting", "begins", "beginning", "beginn", "time", "zeit", "uhrzeit", "heure", "hora", "ora",
    ]

    /// Full month and weekday names in the common European languages and the
    /// user's own, plus short forms in English and the user's languages. Short
    /// forms such as "sam" or "dim" are ordinary words elsewhere.
    private static let vocabulary: (months: Set<String>, weekdays: [String: Int]) = {
        var months: Set<String> = ["sept"]
        var weekdays: [String: Int] = ["tues": 3, "weds": 4, "thur": 5, "thurs": 5]
        let shortForms = Set(["en"] + Locale.preferredLanguages)
        for identifier in Set(["en", "de", "fr", "es", "it"]).union(shortForms) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            let short = shortForms.contains(identifier)
            func names(_ lists: [[String]?]) -> [[String]] {
                lists.map { ($0 ?? []).map { $0.lowercased(with: formatter.locale).trimmingCharacters(in: CharacterSet(charactersIn: ".")) } }
            }
            for list in names([formatter.monthSymbols, formatter.standaloneMonthSymbols]
                + (short ? [formatter.shortMonthSymbols, formatter.shortStandaloneMonthSymbols] : [])) {
                months.formUnion(list.filter { $0.count >= 3 })
            }
            for list in names([formatter.weekdaySymbols, formatter.standaloneWeekdaySymbols]
                + (short ? [formatter.shortWeekdaySymbols, formatter.shortStandaloneWeekdaySymbols] : [])) {
                for (index, name) in list.enumerated() where name.count >= 3 { weekdays[name] = index + 1 }
            }
        }
        // "Mar" is March before it is the Spanish or Italian short Tuesday.
        for name in months { weekdays[name] = nil }
        return (months, weekdays)
    }()

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
    }

    /// Dotted dates put the day first; slashed ones follow the locale unless one
    /// part is over 12. Dashes need a year, since "9-5" and "3-5" are ranges.
    private static func numericDate(in text: String, locale: Locale) -> (year: Int?, month: Int, day: Int, isAmbiguous: Bool)? {
        if let parts = isoDate.captures(in: text), let year = Int(parts[1]), let month = Int(parts[2]), let day = Int(parts[3]) {
            return (1...12).contains(month) && (1...31).contains(day) ? (year, month, day, false) : nil
        }
        guard let parts = shortDate.captures(in: text), let first = Int(parts[1]), let second = Int(parts[3]) else { return nil }
        let year = Int(parts[4]).map { $0 < 100 ? 2000 + $0 : $0 }
        let separator = parts[2]
        if separator == "-", year == nil { return nil }
        let isAmbiguous = separator != "." && first <= 12 && second <= 12
        let dayFirst = separator == "." || first > 12 || isAmbiguous && ordersDayFirst(locale)
        let (day, month) = dayFirst ? (first, second) : (second, first)
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return (year, month, day, isAmbiguous)
    }

    private static func ordersDayFirst(_ locale: Locale) -> Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: locale) ?? ""
        return (format.firstIndex(of: "d") ?? format.startIndex) < (format.firstIndex(of: "M") ?? format.endIndex)
    }

    /// Without a date, the detector picks between 11:00 and 23:00 by the current
    /// time of day. "7pm" it reads reliably; "11 Uhr", "9h30" and "09:30" say
    /// the hour outright. "3:00" could be either, so it reads as office hours
    /// and asks for a check.
    private static func writtenClock(in source: String) -> (clock: DateComponents, isAmbiguous: Bool)? {
        guard !meridiem.matches(source), let parts = clockParts.captures(in: source),
              let hour = Int(parts[1]), hour < 24 else { return nil }
        let isAmbiguous = parts[4].isEmpty && parts[2] != "h" && !parts[1].hasPrefix("0") && (1...12).contains(hour)
        let written = isAmbiguous && hour < 7 ? hour + 12 : hour
        return (DateComponents(hour: written, minute: Int(parts[3]) ?? 0, second: 0), isAmbiguous)
    }

    /// "10.30" is a time when it cannot be a day and month and the detector read it as one.
    private static func isBareTime(in text: String, hour: Int?, minute: Int?) -> Bool {
        guard let parts = bareTime.captures(in: text) else { return false }
        return Int(parts[1]) == hour && Int(parts[2]) == minute
    }

    /// The detector gives a match with "starts" or "begins" an hour of its own,
    /// unless the text writes an end as in "9am-11am" or "until noon".
    private static func inventsDuration(_ source: String) -> Bool {
        startWord.matches(source) && !writtenEnd.matches(isoDate.blanking(source))
    }

    // MARK: - Context

    private static let deadlineStart = Pattern(#"^(?:until|till|til|through|thru|by|before|since|ends?|ending|bis|seit|jusqu\S*|avant|depuis|hasta|antes|entro|fino)\b"#)
    private static let deadlineBefore = Pattern(#"\b(?:until|till|til|through|thru|by|before|since|ends?|ending|closes?|expires?|bis|seit|spätestens|jusqu\S*|avant|depuis|hasta|antes|entro|fino)(?:\s+(?:the|on|of|am|zum|zur|dem|den|le|la|el|il|al|au|de|del|spätestens))*\s*:?\s*\z"#)
    private static let nonEventContext = Pattern(#"\b(?:deadline|due(?!\s+to\b)|expir\w*|last day|closing date|no later than|au plus tard|renew\w*|payment|charged|billed|deliver\w*|arriving|ship(?:s|ped|ping)?|dispatch\w*|tracking|opening hours|business hours|frist\w*|fällig\w*|abgabe\w*|anmeldeschluss|einsendeschluss|liefer(?:ung|termin|datum)\w*|zustell\w*|zahlung\w*|öffnungszeiten|date limite|échéance|livraison|paiement|horaires|entrega|pago|vencimiento|horario|consegna|pagamento|scadenza)\b"#)
    private static let deadlineAfter = Pattern(#"\b(?:deadline|due(?!\s+to\b)|fällig\w*|frist\w*|date limite|échéance|scadenza|vencimiento)\b"#)
    private static let replyHeader = Pattern(#"^\s*(?:sent|gesendet|envoyé|enviado|inviato)\s*:\s*\z"#)
    private static let qualifierBefore = Pattern(#"\b(?:every|each|last|past|previous|jede[nmrs]?|letzte[nmrs]?|vergangene[nmrs]?|chaque|cada|ogni)\s+(?:other\s+)?(\p{L}+)"#)
    private static let qualifierAfter = Pattern(#"(\p{L}+)\s+(?:dernier|dernière|passé|pasado|scorso|scorsa)\b"#)
    private static let sentenceTail = Pattern(#"(?:[^\n.!?;]|[.!?;](?!\s))*\z"#)
    private static let sentenceHead = Pattern(#"^(?:[^\n.!?;]|[.!?;](?!\s))*"#)

    /// Deadlines, validity periods, deliveries, bills and reply headers carry
    /// dates that are not events.
    private static func isDeadline(_ source: String, before: String, after: String) -> Bool {
        deadlineStart.matches(source) || deadlineBefore.matches(before) || nonEventContext.matches(before)
            || deadlineAfter.matches(after) || replyHeader.matches(before)
    }

    /// "every Monday", "letzten Freitag" and "vendredi dernier".
    private static func qualifiesWeekday(in text: String) -> Bool {
        (qualifierBefore.capturedWords(in: text) + qualifierAfter.capturedWords(in: text)).contains { vocabulary.weekdays[$0] != nil }
    }

    /// Up to 60 characters before the match, from the start of its sentence or line.
    private static func sentence(before range: NSRange, in text: NSString) -> String {
        let start = max(0, range.location - 60)
        var prefix = text.substring(with: NSRange(location: start, length: range.location - start))
        if start > 0, let space = prefix.firstIndex(where: \.isWhitespace) { prefix = String(prefix[space...]) }
        return sentenceTail.firstMatch(in: prefix) ?? prefix
    }

    /// Up to 30 characters after the match, to the end of its sentence or line.
    private static func sentence(after range: NSRange, in text: NSString) -> String {
        let start = NSMaxRange(range)
        let suffix = text.substring(with: NSRange(location: start, length: min(30, text.length - start)))
        return sentenceHead.firstMatch(in: suffix) ?? suffix
    }
}

/// A case-insensitive regular expression compiled once. The patterns are
/// literals, so one that fails to compile is a programming error the tests
/// catch; until then it matches nothing.
private struct Pattern: Sendable {
    private let expression: NSRegularExpression?

    init(_ pattern: String) {
        expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    func matches(_ text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func firstMatch(in text: String) -> String? {
        guard let result = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range, in: text) else { return nil }
        return String(text[range])
    }

    /// Every group of the first match, with an empty string for a group that did not take part.
    func captures(in text: String) -> [String]? {
        guard let result = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<result.numberOfRanges).map { Range(result.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    /// The first group of every match.
    func capturedWords(in text: String) -> [String] {
        (expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func blanking(_ text: String) -> String {
        expression?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") ?? text
    }
}
