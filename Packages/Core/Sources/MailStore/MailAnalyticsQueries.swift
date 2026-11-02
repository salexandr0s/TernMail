import Foundation
import GRDB
import MessageContent

extension CacheTransaction {
    public func mailAnalytics(query: MailAnalyticsQuery) throws -> MailAnalyticsSnapshot {
        let accounts = Array(Set(query.accountIDs)).sorted()
        var scope = accounts.isEmpty ? "0" : "m.accountID IN (\(Array(repeating: "?", count: accounts.count).joined(separator: ",")))"
        var arguments = StatementArguments(accounts)
        scope += " AND m.isIncluded = 1"
        if let address = query.contactAddress {
            scope += " AND EXISTS (SELECT 1 FROM mailAnalyticsContact c WHERE c.accountID = m.accountID AND c.messageID = m.messageID AND c.address = ?)"
            arguments += StatementArguments([address])
        }
        let milestones = try Row.fetchOne(db, sql: """
            SELECT MIN(CASE WHEN direction = 'received' THEN date END) AS firstReceived,
                   MIN(CASE WHEN direction = 'sent' THEN date END) AS firstSent,
                   MAX(date) AS lastContact, MIN(date) AS firstContact
            FROM mailAnalyticsMessage m WHERE \(scope)
            """, arguments: arguments)
        let first: Date? = milestones?["firstContact"]
        let ranges = Self.analyticsRanges(query: query, first: first)
        let selected = scope + " AND m.date >= ? AND m.date < ?"
        let selectedArguments = arguments + StatementArguments([ranges.start, ranges.end])
        let totals = try analyticsCounts(where: selected, arguments: selectedArguments)
        let threads = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (SELECT m.accountID, m.threadID FROM mailAnalyticsMessage m
            WHERE \(selected) GROUP BY m.accountID, m.threadID)
            """, arguments: selectedArguments) ?? 0
        let buckets = try ranges.intervals.map { range in
            let counts = try analyticsCounts(where: scope + " AND m.date >= ? AND m.date < ?",
                                            arguments: arguments + StatementArguments([range.start, range.end]))
            return MailAnalyticsBucket(date: range.start, sentCount: counts.sent, receivedCount: counts.received)
        }
        let correspondents = try Row.fetchAll(db, sql: """
            SELECT c.address, MAX(c.name) AS name,
                   SUM(CASE WHEN m.direction = 'sent' THEN 1 ELSE 0 END) AS sent,
                   SUM(CASE WHEN m.direction = 'received' THEN 1 ELSE 0 END) AS received,
                   MAX(m.date) AS lastContact
            FROM mailAnalyticsMessage m
            JOIN mailAnalyticsContact c ON c.accountID = m.accountID AND c.messageID = m.messageID
            WHERE \(selected) AND NOT EXISTS (SELECT 1 FROM ownAddress o WHERE o.accountID = c.accountID AND o.address = c.address)
            GROUP BY c.address ORDER BY COUNT(*) DESC, lastContact DESC, c.address LIMIT 12
            """, arguments: selectedArguments).map { row in
                MailAnalyticsCorrespondent(address: row["address"], name: row["name"], sentCount: row["sent"],
                    receivedCount: row["received"], lastContactAt: row["lastContact"])
            }
        let recent = try MailAnalyticsRecord.fetchAll(db, sql: """
            SELECT m.* FROM mailAnalyticsMessage m WHERE \(selected)
            ORDER BY m.date DESC, m.accountID, m.messageID LIMIT 20
            """, arguments: selectedArguments).map {
                MailAnalyticsMessage(accountID: $0.accountID, messageID: $0.messageID, threadID: $0.threadID,
                    date: $0.date, subject: $0.subject, sender: $0.sender, direction: $0.direction)
            }
        let profiles: [MailAnalyticsProfileSource]
        if let address = query.contactAddress {
            profiles = try Row.fetchAll(db, sql: """
                SELECT m.accountID, m.messageID, m.date,
                    CASE WHEN length(CAST(b.plainText AS BLOB)) <= \(SenderProfileLinks.maximumInputBytes) THEN b.plainText END AS plainText,
                    CASE WHEN length(CAST(b.html AS BLOB)) <= \(SenderProfileLinks.maximumInputBytes) THEN b.html END AS html
                FROM mailAnalyticsMessage m JOIN messageBody b ON b.accountID = m.accountID AND b.messageID = m.messageID
                WHERE \(scope) AND m.direction = 'received' AND m.senderAddress = ?
                ORDER BY m.date DESC, m.accountID, m.messageID LIMIT 12
                """, arguments: arguments + StatementArguments([address])).map {
                    MailAnalyticsProfileSource(accountID: $0["accountID"], messageID: $0["messageID"], date: $0["date"],
                        plainText: $0["plainText"], html: $0["html"])
                }
        } else { profiles = [] }
        return MailAnalyticsSnapshot(sentCount: totals.sent, receivedCount: totals.received, threadCount: threads,
            firstReceivedAt: milestones?["firstReceived"], firstSentAt: milestones?["firstSent"], lastContactAt: milestones?["lastContact"],
            bucketUnit: ranges.unit, buckets: buckets, correspondents: correspondents, recentMessages: recent,
            coverage: try accounts.map { try analyticsCoverage(accountID: $0) }, profileSources: profiles)
    }

    private func analyticsCounts(where predicate: String, arguments: StatementArguments) throws -> (sent: Int, received: Int) {
        let row = try Row.fetchOne(db, sql: """
            SELECT SUM(CASE WHEN m.direction = 'sent' THEN 1 ELSE 0 END) AS sent,
                   SUM(CASE WHEN m.direction = 'received' THEN 1 ELSE 0 END) AS received
            FROM mailAnalyticsMessage m WHERE \(predicate)
            """, arguments: arguments)
        return (row?["sent"] ?? 0, row?["received"] ?? 0)
    }

    private static func analyticsRanges(query: MailAnalyticsQuery, first: Date?) -> (start: Date, end: Date, unit: MailAnalyticsBucketUnit, intervals: [DateInterval]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = query.timeZone
        let today = calendar.startOfDay(for: query.now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? query.now
        let month = calendar.dateInterval(of: .month, for: query.now)?.start ?? today
        let start: Date
        var component = Calendar.Component.month
        switch query.period {
        case .month, .quarter:
            component = .day
            start = calendar.date(byAdding: .day, value: query.period == .month ? -29 : -89, to: today) ?? today
        case .year:
            start = calendar.date(byAdding: .month, value: -11, to: month) ?? month
        case .allTime:
            let earliest = min(first ?? query.now, query.now)
            let months = calendar.dateComponents([.month], from: earliest, to: query.now).month ?? 0
            component = months > 240 ? .year : .month
            start = calendar.dateInterval(of: component, for: earliest)?.start ?? today
        }
        var intervals: [DateInterval] = []
        var cursor = start
        // Calendar boundaries keep DST days intact. A bound also contains malformed dates.
        while cursor < end, intervals.count < 366 {
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
            intervals.append(DateInterval(start: cursor, end: min(next, end)))
            cursor = next
        }
        if cursor < end, let last = intervals.popLast() {
            intervals.append(DateInterval(start: last.start, end: end))
        }
        let unit: MailAnalyticsBucketUnit = component == .day ? .day : component == .year ? .year : .month
        return (start, end, unit, intervals)
    }
}
