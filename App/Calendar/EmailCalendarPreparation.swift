import CryptoKit
import Foundation
import MailStore
import MessageContent

struct EmailCalendarSource: Sendable {
    let id: String
    let subject: String
    let date: Date
    let html: String?
    let plainText: String?
    let invitations: [Invitation]
    let sender: String
    let allowsDateDetection: Bool
    let dateHeaderOffset: Int?
}

struct PreparedEmailCalendarMessages: Sendable {
    let messages: [EmailCalendarMessage]
    let revision: String
    let detections: [String: [DetectedCalendarSuggestion]]
}

/// Serial preparation keeps HTML parsing and NSDataDetector off the UI executor.
/// A read/star change supplies the same content key, so neither runs again.
actor EmailCalendarPreparation {
    static let shared = EmailCalendarPreparation()
    let capacity: Int
    private(set) var cost = 0
    private(set) var preparationCount = 0
    private var sequence = 0
    private var entries: [Key: Entry] = [:]

    private struct Key: Hashable {
        let accountID: String
        let lifetime: String
        let source: String
        let timeZoneID: String
        let localeID: String
    }
    private struct Entry {
        let message: EmailCalendarMessage
        let detections: [DetectedCalendarSuggestion]
        let cost: Int
        var used: Int
    }

    init(capacity: Int = 8 * 1_024 * 1_024) { self.capacity = max(0, capacity) }

    func prepare(detail: ThreadDetail, invitations: [MessageCalendarRecord], accountID: String,
                 lifetime: String, timeZone: TimeZone) throws -> PreparedEmailCalendarMessages {
        try Task.checkCancellation()
        let byMessage = Dictionary(grouping: invitations, by: \.messageID)
        let sources = detail.messages.map { message in
            EmailCalendarSource(id: message.id, subject: message.record.subject, date: message.record.date,
                html: message.body?.html, plainText: message.body?.plainText,
                invitations: byMessage[message.id]?.map(\.invitation) ?? [], sender: message.record.sender,
                allowsDateDetection: message.labels.isDisjoint(with: ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"]),
                dateHeaderOffset: message.record.dateHeaderOffset)
        }
        return try prepare(sources, accountID: accountID, lifetime: lifetime, timeZone: timeZone)
    }

    func prepare(_ sources: [EmailCalendarSource], accountID: String, lifetime: String,
                 timeZone: TimeZone, locale: Locale = .autoupdatingCurrent) throws -> PreparedEmailCalendarMessages {
        try Task.checkCancellation()
        var messages: [EmailCalendarMessage] = []
        var detections: [String: [DetectedCalendarSuggestion]] = [:]
        for source in sources {
            try Task.checkCancellation()
            let key = Key(accountID: accountID, lifetime: lifetime, source: Self.fingerprint(source),
                          timeZoneID: timeZone.identifier, localeID: locale.identifier)
            sequence += 1
            let entry: Entry
            if var cached = entries[key] {
                cached.used = sequence
                entries[key] = cached
                entry = cached
            } else {
                let text = CalendarDetection.readableText(html: source.html, plainText: source.plainText)
                try Task.checkCancellation()
                let message = EmailCalendarMessage(id: source.id, subject: source.subject, date: source.date,
                    text: text, invitations: source.invitations, sender: source.sender,
                    allowsDateDetection: source.allowsDateDetection, dateHeaderOffset: source.dateHeaderOffset)
                let found = source.invitations.isEmpty && source.allowsDateDetection
                    ? CalendarDetection.suggestions(in: text, messageDate: source.date, timeZone: timeZone, locale: locale) : []
                try Task.checkCancellation()
                let bytes = 512 + text.utf8.count + source.subject.utf8.count + source.sender.utf8.count
                    + ((try? JSONEncoder().encode(source.invitations).count) ?? 0)
                entry = Entry(message: message, detections: found,
                    cost: bytes + found.reduce(0) { $0 + $1.sourceText.utf8.count + 256 }, used: sequence)
                preparationCount += 1
                if entry.cost <= capacity {
                    while cost + entry.cost > capacity,
                          let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
                        remove(oldest)
                    }
                    entries[key] = entry
                    cost += entry.cost
                }
            }
            messages.append(entry.message)
            detections[entry.message.id] = entry.detections
        }
        return PreparedEmailCalendarMessages(messages: messages,
            revision: EmailCalendarModel.fingerprint(messages, timeZone: timeZone), detections: detections)
    }

    func remove(accountID: String) {
        for key in entries.keys.filter({ $0.accountID == accountID }) { remove(key) }
    }

    func removeAll() { entries.removeAll(); cost = 0 }

    private func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { cost -= entry.cost }
    }

    private static func fingerprint(_ source: EmailCalendarSource) -> String {
        var hash = SHA256()
        for field in [source.id, source.subject, String(source.date.timeIntervalSince1970), source.html ?? "",
                      source.plainText ?? "", source.sender, source.dateHeaderOffset.map(String.init) ?? "",
                      source.allowsDateDetection ? "detect" : "skip"] {
            hash.update(data: Data("\(field.utf8.count):".utf8))
            hash.update(data: Data(field.utf8))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(source.invitations) { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
