import Foundation
import GRDB

/// Organizer versions must outlive older cached requests, so eviction cannot revive an obsolete response.
struct CalendarInvitationCacheSource: Hashable {
    let thread: CacheThreadReference
    let messageID: String
}

extension CacheTransaction {
    /// Only metadata is retained. Bodies and MIME resources remain disposable.
    func newestInvitationSources(accountID: String? = nil) throws -> Set<CalendarInvitationCacheSource> {
        struct EventKey: Hashable {
            let accountID: String
            let uid: String
            let recurrenceKey: String
        }
        struct Latest {
            var sequence: Int
            var stamp: Date
            var sources: Set<CalendarInvitationCacheSource>
        }
        var sql = """
            SELECT c.*,m.threadID AS sourceThreadID FROM messageCalendar c JOIN message m
            ON m.accountID=c.accountID AND m.id=c.messageID
            """
        var arguments = StatementArguments()
        if let accountID {
            sql += " WHERE c.accountID = ?"
            arguments += [accountID]
        }
        var latest: [EventKey: Latest] = [:]
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
            let record = try MessageCalendarRecord(row: row)
            let source = CalendarInvitationCacheSource(
                thread: .init(accountID: record.accountID, threadID: row["sourceThreadID"]), messageID: record.messageID)
            for invitation in [record.invitation] + (record.invitation.additionalEvents ?? []) where !invitation.isAttendeeMessage {
                let key = EventKey(accountID: record.accountID, uid: invitation.uid, recurrenceKey: invitation.recurrenceKey)
                let stamp = invitation.stamp ?? .distantPast
                if let previous = latest[key] {
                    if (previous.sequence, previous.stamp) > (invitation.sequence, stamp) { continue }
                    if (previous.sequence, previous.stamp) == (invitation.sequence, stamp) {
                        latest[key]?.sources.insert(source)
                        continue
                    }
                }
                latest[key] = Latest(sequence: invitation.sequence, stamp: stamp, sources: [source])
            }
        }
        return latest.values.reduce(into: []) { $0.formUnion($1.sources) }
    }
}
