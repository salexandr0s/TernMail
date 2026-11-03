import Foundation
import GRDB

extension CacheTransaction {
    /// A bounded startup scan. Callers refresh the thread before using this cached evidence.
    public func automaticFollowUpCandidates(accountID: String, since: Date, limit: Int = 100) throws -> [MessageRecord] {
        guard since.timeIntervalSince1970.isFinite, limit > 0 else { return [] }
        return try MessageRecord.fetchAll(db, sql: """
            WITH sent AS (
                SELECT m.*, ROW_NUMBER() OVER (PARTITION BY m.threadID ORDER BY m.date DESC, m.id DESC) AS sentOrder
                FROM message m WHERE m.accountID = ? AND m.date >= ? AND m.id NOT LIKE 'local-send:%'
                AND EXISTS (SELECT 1 FROM messageLabel l WHERE l.accountID = m.accountID AND l.messageID = m.id AND l.labelID = 'SENT')
                AND NOT EXISTS (SELECT 1 FROM messageLabel l WHERE l.accountID = m.accountID AND l.messageID = m.id
                    AND l.labelID IN ('DRAFT', 'TRASH', 'SPAM'))
                AND NOT EXISTS (SELECT 1 FROM effectiveLabel l WHERE l.accountID = m.accountID AND l.messageID = m.id
                    AND l.labelID IN ('DRAFT', 'TRASH', 'SPAM'))
            ) SELECT * FROM sent WHERE sentOrder = 1 ORDER BY date DESC, id DESC LIMIT ?
            """, arguments: [accountID, since, min(limit, 100)])
    }
}
