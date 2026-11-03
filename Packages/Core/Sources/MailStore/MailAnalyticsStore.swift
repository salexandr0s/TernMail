import Foundation
import GRDB
import MessageContent

extension MailCache {
    public func mailAnalytics(query: MailAnalyticsQuery) async throws -> MailAnalyticsSnapshot {
        try await read { try $0.mailAnalytics(query: query) }
    }

    public func observeMailAnalytics(query: MailAnalyticsQuery) -> AsyncThrowingStream<MailAnalyticsSnapshot, any Error> {
        observe(latestOnly: true) { try CacheTransaction(db: $0).mailAnalytics(query: query) }
    }
}

extension CacheTransaction {
    /// SENT determines direction, including messages sent through aliases. Self-addressed
    /// mail counts once as sent. Sent correspondents include To, Cc and provider-visible Bcc.
    public func upsertAnalyticsMessages(_ updates: [MessageUpdate], generation: String? = nil) throws {
        // Upgrade fixtures can write messages before this migration has run.
        guard try db.tableExists(MailAnalyticsRecord.databaseTableName) else { return }
        for update in updates where !LocalSend.isProvisional(update.record.id) {
            let message = update.record
            if message.bcc != nil {
                try finishRecipientHeaderBackfill(messageIDs: [message.id], accountID: message.accountID)
            }
            let old = try MailAnalyticsRecord.fetchOne(db, key: ["accountID": message.accountID, "messageID": message.id])
            let active = try analyticsIndexState(accountID: message.accountID)
            let marker = generation ?? (active?.isComplete == false ? active?.generation : nil) ?? old?.generation
            if let old, old.historyID > message.historyID {
                if let marker, marker != old.generation {
                    try db.execute(sql: "UPDATE mailAnalyticsMessage SET generation = ? WHERE accountID = ? AND messageID = ?",
                                   arguments: [marker, message.accountID, message.id])
                }
                continue
            }
            let labels = Set(update.labelIDs)
            let sender = EmailAddress.parseList(message.sender).first
            let record = MailAnalyticsRecord(accountID: message.accountID, messageID: message.id,
                threadID: message.threadID, historyID: message.historyID, date: message.date,
                subject: message.subject, sender: message.sender, senderAddress: sender?.normalized ?? "",
                recipients: message.recipients, cc: message.cc, bcc: message.bcc ?? old?.bcc, labelIDs: labels.sorted(),
                direction: labels.contains(SystemLabel.sent) ? .sent : .received,
                isIncluded: labels.isDisjoint(with: [SystemLabel.draft, SystemLabel.spam, SystemLabel.trash, LocalSend.label]),
                generation: marker)
            guard record != old else { continue }
            try record.upsert(db)
            try replaceAnalyticsContacts(record)
        }
    }

    private func replaceAnalyticsContacts(_ message: MailAnalyticsRecord) throws {
        let addresses = message.direction == .sent
            ? EmailAddress.parseList(message.recipients) + EmailAddress.parseList(message.cc ?? "") + EmailAddress.parseList(message.bcc ?? "")
            : EmailAddress.parseList(message.sender)
        try db.execute(sql: "DELETE FROM mailAnalyticsContact WHERE accountID = ? AND messageID = ?",
                       arguments: [message.accountID, message.messageID])
        var seen = Set<String>()
        for address in addresses where address.isValid && seen.insert(address.normalized).inserted {
            try db.execute(sql: "INSERT INTO mailAnalyticsContact (accountID,messageID,address,name) VALUES (?,?,?,?)",
                           arguments: [message.accountID, message.messageID, address.normalized, address.name])
        }
    }

    /// Use only for confirmed provider deletions. Cache eviction must retain these rows.
    public func deleteAnalyticsMessages(messageIDs: [String], accountID: String) throws {
        guard try db.tableExists(MailAnalyticsRecord.databaseTableName) else { return }
        for id in Set(messageIDs) {
            try MailAnalyticsRecord.filter(Column("accountID") == accountID && Column("messageID") == id).deleteAll(db)
        }
    }

    public func applyAnalyticsLabelChange(messageID: String, added: [String], removed: [String],
                                         historyID: Int64, accountID: String) throws {
        guard try db.tableExists(MailAnalyticsRecord.databaseTableName),
              var record = try MailAnalyticsRecord.fetchOne(db, key: ["accountID": accountID, "messageID": messageID]),
              record.historyID <= historyID else { return }
        let labels = Set(record.labelIDs).union(added).subtracting(removed)
        record.labelIDs = labels.sorted()
        record.historyID = historyID
        record.direction = labels.contains(SystemLabel.sent) ? .sent : .received
        record.isIncluded = labels.isDisjoint(with: [SystemLabel.draft, SystemLabel.spam, SystemLabel.trash, LocalSend.label])
        if let state = try analyticsIndexState(accountID: accountID), !state.isComplete { record.generation = state.generation }
        try record.update(db)
        try replaceAnalyticsContacts(record)
    }

    public func analyticsIndexState(accountID: String) throws -> MailAnalyticsIndexState? {
        try MailAnalyticsIndexState.fetchOne(db, key: accountID)
    }

    public func beginAnalyticsHistory(accountID: String, restart: Bool = false) throws -> MailAnalyticsIndexState {
        let old = try analyticsIndexState(accountID: accountID)
        if let old, !restart { return old }
        let state = MailAnalyticsIndexState(accountID: accountID, historyLoadedAt: old?.historyLoadedAt)
        try state.upsert(db)
        return state
    }

    /// Requests that raced with restart or another completed page cannot rewind the checkpoint.
    public func commitAnalyticsHistoryPage(_ expected: MailAnalyticsIndexState, updates: [MessageUpdate],
                                           missing: Set<String>, nextPageToken: String?, loadedAt: Date) throws -> MailAnalyticsCoverage {
        guard var current = try analyticsIndexState(accountID: expected.accountID),
              current.generation == expected.generation, current.nextPageToken == expected.nextPageToken,
              !current.isComplete else { return try analyticsCoverage(accountID: expected.accountID) }
        try upsertAnalyticsMessages(updates, generation: current.generation)
        try deleteAnalyticsMessages(messageIDs: Array(missing), accountID: expected.accountID)
        current.nextPageToken = nextPageToken
        current.isComplete = nextPageToken == nil
        current.lastError = nil
        if current.isComplete {
            current.historyLoadedAt = loadedAt
            try db.execute(sql: "DELETE FROM mailAnalyticsMessage WHERE accountID = ? AND isIncluded = 1 AND (generation IS NULL OR generation != ?)",
                           arguments: [current.accountID, current.generation])
        }
        try current.upsert(db)
        return try analyticsCoverage(accountID: expected.accountID)
    }

    public func failAnalyticsHistory(_ expected: MailAnalyticsIndexState, paginationExpired: Bool) throws {
        guard var current = try analyticsIndexState(accountID: expected.accountID),
              current.generation == expected.generation, current.nextPageToken == expected.nextPageToken,
              !current.isComplete else { return }
        if paginationExpired {
            current.generation = UUID().uuidString
            current.nextPageToken = nil
        }
        current.lastError = paginationExpired ? "History loading expired. Try again to restart it." : "History loading stopped. Try again to continue."
        try current.upsert(db)
    }

    /// A provider history reset means deletions may have been missed. Keep the rows and
    /// last snapshot date, but require a fresh listing before claiming the scan finished.
    public func invalidateAnalyticsCoverage(accountID: String) throws {
        guard try db.tableExists(MailAnalyticsIndexState.databaseTableName),
              let old = try analyticsIndexState(accountID: accountID) else { return }
        let state = MailAnalyticsIndexState(accountID: accountID, historyLoadedAt: old.historyLoadedAt,
            lastError: "Mail history changed. Reload history to update this snapshot.")
        try state.upsert(db)
    }

    public func analyticsCoverage(accountID: String) throws -> MailAnalyticsCoverage {
        let state = try analyticsIndexState(accountID: accountID)
        let count = try MailAnalyticsRecord.filter(Column("accountID") == accountID && Column("isIncluded") == true).fetchCount(db)
        return MailAnalyticsCoverage(accountID: accountID, indexedMessageCount: count,
            historyLoadedAt: state?.historyLoadedAt, nextPageToken: state?.nextPageToken,
            isComplete: state?.isComplete ?? false, lastError: state?.lastError)
    }
}
