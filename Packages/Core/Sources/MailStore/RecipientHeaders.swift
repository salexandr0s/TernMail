import GRDB

extension CacheTransaction {
    /// Only migration-era records are queued; ordinary cache fixtures and new
    /// records do not turn every sync into a historical metadata scan.
    public func pendingRecipientHeaderBackfill(accountID: String, limit: Int = 25) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT messageID FROM recipientHeaderBackfill WHERE accountID = ?
            ORDER BY messageID LIMIT ?
            """, arguments: [accountID, limit])
    }

    public func finishRecipientHeaderBackfill(messageIDs: [String], accountID: String) throws {
        for id in messageIDs {
            try db.execute(sql: "DELETE FROM recipientHeaderBackfill WHERE accountID = ? AND messageID = ?",
                arguments: [accountID, id])
        }
    }
}
