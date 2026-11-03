import Foundation
import GRDB

public enum NewsletterStoreError: Error, Sendable {
    case repeatedPageToken
}

extension MailCache {
    public func newsletters(accountID: String) async throws -> NewsletterSnapshot {
        try await read { try $0.newsletters(accountID: accountID) }
    }

    public func observeNewsletters(accountID: String) -> AsyncThrowingStream<NewsletterSnapshot, any Error> {
        observe { try CacheTransaction(db: $0).newsletters(accountID: accountID) }
    }
}

extension CacheTransaction {
    public func newsletterScanState(accountID: String) throws -> NewsletterScanState? {
        try NewsletterScanState.fetchOne(db, key: accountID)
    }

    public func beginNewsletterScan(accountID: String, restart: Bool = false) throws -> NewsletterScanState {
        let old = try newsletterScanState(accountID: accountID)
        if let old, !restart { return old }
        let generation = UUID().uuidString
        let state = NewsletterScanState(accountID: accountID, generation: generation,
            displayedGeneration: old?.displayedGeneration ?? generation, isComplete: false,
            lastScannedAt: old?.lastScannedAt)
        try state.upsert(db)
        try db.execute(sql: "DELETE FROM newsletterMessage WHERE accountID=? AND generation != ?",
            arguments: [accountID, state.displayedGeneration])
        try db.execute(sql: "DELETE FROM newsletterScanToken WHERE accountID=?", arguments: [accountID])
        return state
    }

    public func commitNewsletterPage(_ expected: NewsletterScanState, messages: [NewsletterMessage],
                                     nextPageToken: String?, now: Date) throws -> NewsletterSnapshot {
        guard var current = try newsletterScanState(accountID: expected.accountID),
              current.generation == expected.generation, current.nextPageToken == expected.nextPageToken,
              !current.isComplete else { return try newsletters(accountID: expected.accountID) }
        if let token = nextPageToken {
            let repeated = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM newsletterScanToken WHERE accountID=? AND generation=? AND token=?)
                """, arguments: [current.accountID, current.generation, token]) ?? false
            guard !repeated, token != current.nextPageToken else { throw NewsletterStoreError.repeatedPageToken }
            try db.execute(sql: "INSERT INTO newsletterScanToken (accountID,generation,token) VALUES (?,?,?)",
                arguments: [current.accountID, current.generation, token])
        }
        for message in messages where message.accountID == current.accountID && message.generation == current.generation {
            try message.upsert(db)
        }
        current.nextPageToken = nextPageToken
        current.lastError = nil
        current.isComplete = nextPageToken == nil
        if current.isComplete {
            current.displayedGeneration = current.generation
            current.lastScannedAt = now
            try db.execute(sql: "DELETE FROM newsletterMessage WHERE accountID=? AND generation != ?",
                arguments: [current.accountID, current.generation])
            try db.execute(sql: "DELETE FROM newsletterScanToken WHERE accountID=?", arguments: [current.accountID])
        }
        try current.update(db)
        return try newsletters(accountID: current.accountID)
    }

    public func failNewsletterScan(_ expected: NewsletterScanState, paginationExpired: Bool = false) throws {
        guard var current = try newsletterScanState(accountID: expected.accountID),
              current.generation == expected.generation, current.nextPageToken == expected.nextPageToken,
              !current.isComplete else { return }
        if paginationExpired {
            current = try beginNewsletterScan(accountID: current.accountID, restart: true)
        }
        current.lastError = paginationExpired
            ? "The mail scan expired. Continue to start a new scan."
            : "The mail scan stopped. Continue to try this page again."
        try current.update(db)
    }

    public func newsletters(accountID: String) throws -> NewsletterSnapshot {
        guard let state = try newsletterScanState(accountID: accountID) else { return .init(accountID: accountID) }
        func count(_ generation: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM newsletterMessage WHERE accountID=? AND generation=?",
                arguments: [accountID, generation]) ?? 0
        }
        return try .init(accountID: accountID, subscriptions: newsletterSubscriptions(accountID: accountID,
            generation: state.displayedGeneration), scannedMessageCount: count(state.generation),
            displayedScannedMessageCount: count(state.displayedGeneration), isComplete: state.isComplete,
            isRefreshing: state.generation != state.displayedGeneration, lastScannedAt: state.lastScannedAt,
            lastError: state.lastError)
    }

    public func newsletter(id: String, accountID: String) throws -> NewsletterSubscription? {
        guard let state = try newsletterScanState(accountID: accountID) else { return nil }
        return try newsletterSubscriptions(accountID: accountID, generation: state.displayedGeneration, id: id).first
    }

    private func newsletterSubscriptions(accountID: String, generation: String, id: String? = nil)
        throws -> [NewsletterSubscription] {
        var arguments: StatementArguments = [accountID, generation]
        let restriction: String
        if let id { restriction = " AND subscriptionID=?"; arguments += [id] }
        else { restriction = "" }
        let rows = try Row.fetchAll(db, sql: """
            WITH ranked AS (
                SELECT *, COUNT(*) OVER (PARTITION BY subscriptionID) AS messageCount,
                    ROW_NUMBER() OVER (PARTITION BY subscriptionID ORDER BY date DESC,messageID DESC) AS rowNumber
                FROM newsletterMessage WHERE accountID=? AND generation=? AND subscriptionID IS NOT NULL\(restriction)
            )
            SELECT r.*,o.status,o.statusDate,o.lastError FROM ranked r LEFT JOIN newsletterOutcome o
                ON o.accountID=r.accountID AND o.subscriptionID=r.subscriptionID
            WHERE r.rowNumber=1 ORDER BY r.messageCount DESC,r.date DESC,r.subscriptionID
            """, arguments: arguments)
        return rows.map { row in
            func url(_ name: String) -> URL? { (row[name] as String?).flatMap(URL.init(string:)) }
            let rawStatus: String? = row["status"]
            return NewsletterSubscription(id: row["subscriptionID"], accountID: row["accountID"],
                senderAddress: row["senderAddress"], senderName: row["senderName"], listID: row["listID"],
                latestMessageID: row["messageID"], latestThreadID: row["threadID"], latestSubject: row["subject"],
                latestDate: row["date"], messageCount: row["messageCount"], unsubscribeURL: url("webURL"),
                mailtoURL: url("mailtoURL"), oneClickURL: url("oneClickURL"),
                status: rawStatus.flatMap(NewsletterUnsubscribeStatus.init(rawValue:)) ?? .active,
                statusDate: row["statusDate"], lastError: row["lastError"])
        }
    }

    /// The claim and eligibility check share a transaction, so separate windows
    /// cannot submit the same list at once. Only explicit user retries claim failed rows.
    public func claimNewsletterRequest(id: String, accountID: String, requestID: String, now: Date)
        throws -> NewsletterSubscription? {
        guard let row = try newsletter(id: id, accountID: accountID), row.canUnsubscribeAutomatically else { return nil }
        try setNewsletterOutcome(id: id, accountID: accountID, status: .requesting, now: now, requestID: requestID)
        return try newsletter(id: id, accountID: accountID)
    }

    public func finishNewsletterRequest(id: String, accountID: String, requestID: String,
                                        accepted: Bool, error: String? = nil, now: Date) throws {
        try db.execute(sql: """
            UPDATE newsletterOutcome SET status=?,statusDate=?,lastError=?,requestID=NULL
            WHERE accountID=? AND subscriptionID=? AND status='requesting' AND requestID=?
            """, arguments: [accepted ? "requested" : "failed", now, error, accountID, id, requestID])
    }

    /// Another engine/process owned these requests. Their outcome is unknown;
    /// they remain visible for an explicit retry instead of being replayed.
    public func recoverNewsletterRequests(accountID: String, ownerID: String,
                                           abandonedRequestIDs: Set<String> = [], now: Date) throws {
        try db.execute(sql: """
            UPDATE newsletterOutcome SET status='failed',statusDate=?,requestID=NULL,
                lastError='The request was interrupted and may have reached the sender. Check before retrying.'
            WHERE accountID=? AND status='requesting' AND (requestID IS NULL OR requestID NOT LIKE ?)
            """, arguments: [now, accountID, ownerID + ":%"])
        for requestID in abandonedRequestIDs {
            try db.execute(sql: """
                UPDATE newsletterOutcome SET status='failed',statusDate=?,requestID=NULL,
                    lastError='The request outcome could not be saved and may have reached the sender. Check before retrying.'
                WHERE accountID=? AND status='requesting' AND requestID=?
                """, arguments: [now, accountID, requestID])
        }
    }

    @discardableResult
    public func markNewsletterOpened(id: String, accountID: String, now: Date) throws -> NewsletterSubscription? {
        guard let row = try newsletter(id: id, accountID: accountID),
              row.status == .active || row.status == .failed || row.status == .opened,
              row.unsubscribeURL != nil || row.mailtoURL != nil else { return nil }
        try setNewsletterOutcome(id: id, accountID: accountID, status: .opened, now: now)
        return try newsletter(id: id, accountID: accountID)
    }

    @discardableResult
    public func confirmNewsletterUnsubscribed(id: String, accountID: String, now: Date) throws -> NewsletterSubscription? {
        guard let row = try newsletter(id: id, accountID: accountID), row.status == .opened else { return nil }
        try setNewsletterOutcome(id: id, accountID: accountID, status: .completed, now: now)
        return try newsletter(id: id, accountID: accountID)
    }

    @discardableResult
    public func resetNewsletterStatus(id: String, accountID: String) throws -> NewsletterSubscription? {
        guard let row = try newsletter(id: id, accountID: accountID), row.status != .requesting else { return nil }
        try db.execute(sql: "DELETE FROM newsletterOutcome WHERE accountID=? AND subscriptionID=?", arguments: [accountID, id])
        return try newsletter(id: id, accountID: accountID)
    }

    private func setNewsletterOutcome(id: String, accountID: String, status: NewsletterUnsubscribeStatus,
                                      now: Date, requestID: String? = nil) throws {
        try db.execute(sql: """
            INSERT INTO newsletterOutcome (accountID,subscriptionID,status,statusDate,lastError,requestID)
            VALUES (?,?,?,?,NULL,?) ON CONFLICT(accountID,subscriptionID) DO UPDATE SET
                status=excluded.status,statusDate=excluded.statusDate,lastError=NULL,requestID=excluded.requestID
            """, arguments: [accountID, id, status.rawValue, now, requestID])
    }
}
