import Foundation
import GRDB

extension AccountStore {
    public func todayVisitBaseline(scope: TodayScope, accountIDs: Set<String>) async throws -> TodayVisitBaseline {
        try Task.checkCancellation()
        return try await writer.read { db in
            try Task.checkCancellation()
            let allowed = try Self.todayAccountIDs(db, scope: scope).intersection(accountIDs)
            let initialized = try Self.initializedTodayAccounts(db, scope: scope).intersection(allowed)
            guard !allowed.isEmpty else {
                return TodayVisitBaseline(scope: scope, accountIDs: [], initializedAccountIDs: [], snapshots: [:])
            }
            let ids = allowed.sorted()
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT accountID,commitmentID,snapshot FROM todaySeenCommitment
                WHERE scopeKey = ? AND accountID IN (\(placeholders))
                """, arguments: StatementArguments([scope.storageKey] + ids))
            var snapshots: [String: TodayCommitmentSnapshot] = [:]
            for row in rows {
                let payload: String = row["snapshot"]
                let snapshot = try JSONDecoder().decode(TodayCommitmentSnapshot.self, from: Data(payload.utf8))
                guard snapshot.accountID == (row["accountID"] as String),
                      snapshot.commitmentID == (row["commitmentID"] as String) else { throw TodayVisitStoreError.invalidSnapshot }
                snapshots[snapshot.id] = snapshot
            }
            return TodayVisitBaseline(scope: scope, accountIDs: allowed, initializedAccountIDs: initialized, snapshots: snapshots)
        }
    }

    /// Stores only the captured presentation. First visits additionally seed their captured full census.
    public func acknowledgeTodayVisit(scope: TodayScope, accountIDs: Set<String>, presentedEntries: [CommitmentEntry],
                                       initialEntries: [CommitmentEntry], now: Date = Date()) async throws -> TodayVisitAcknowledgement {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite else { throw TodayVisitStoreError.invalidSnapshot }
        try Self.validateTodayCapture(presentedEntries, accountIDs: accountIDs)
        try Self.validateTodayCapture(initialEntries, accountIDs: accountIDs)
        return try await writer.write { db in
            try Task.checkCancellation()
            let allowed = try Self.todayAccountIDs(db, scope: scope)
            guard accountIDs.isSubset(of: allowed) else { throw TodayVisitStoreError.unavailableScope }
            let current = try Self.currentCommitmentEntries(db, accountIDs: accountIDs)
            let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
            let currentByAccount = Dictionary(grouping: current, by: \.record.accountID)
            let initialByAccount = Dictionary(grouping: initialEntries, by: \.record.accountID)
            var initialized = try Self.initializedTodayAccounts(db, scope: scope).intersection(accountIDs)
            var acknowledged: Set<String> = []

            for accountID in accountIDs.sorted() where !initialized.contains(accountID) {
                try Task.checkCancellation()
                let captured = initialByAccount[accountID] ?? []
                let latest = currentByAccount[accountID] ?? []
                // New unseen rows or edits cannot be consumed by an older first-visit load.
                guard Set(captured.map(\.id)) == Set(latest.map(\.id)),
                      captured.allSatisfy({ Self.matchesCurrentTodayContent($0, current: currentByID[$0.id]) }) else { continue }
                try db.execute(sql: """
                    INSERT INTO todayVisit(scopeKey,profileID,accountID,firstVisitedAt,lastVisitedAt) VALUES (?,?,?,?,?)
                    """, arguments: [scope.storageKey, scope.profileID, accountID, now, now])
                initialized.insert(accountID)
                for entry in captured {
                    if try Self.writeTodaySnapshot(db, scope: scope, entry: entry, now: now) { acknowledged.insert(entry.id) }
                }
            }

            for entry in presentedEntries where initialized.contains(entry.record.accountID) {
                try Task.checkCancellation()
                guard Self.matchesCurrentTodayContent(entry, current: currentByID[entry.id]) else { continue }
                if try Self.writeTodaySnapshot(db, scope: scope, entry: entry, now: now) { acknowledged.insert(entry.id) }
            }
            for accountID in initialized {
                try db.execute(sql: """
                    UPDATE todayVisit SET lastVisitedAt = MAX(lastVisitedAt, ?) WHERE scopeKey = ? AND accountID = ?
                    """, arguments: [now, scope.storageKey, accountID])
            }
            try Task.checkCancellation()
            return TodayVisitAcknowledgement(initializedAccountIDs: initialized, acknowledgedIDs: acknowledged)
        }
    }
}

private extension AccountStore {
    static func todayAccountIDs(_ db: Database, scope: TodayScope) throws -> Set<String> {
        if let profileID = scope.profileID {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM mailProfile WHERE id = ?)", arguments: [profileID]) == true else {
                throw TodayVisitStoreError.unavailableScope
            }
            return try String.fetchSet(db, sql: """
                SELECT account.id FROM account JOIN accountMailPreference p ON p.accountID = account.id
                WHERE p.profileID = ? AND NOT EXISTS(SELECT 1 FROM pendingAccountRemoval r WHERE r.accountID = account.id)
                """, arguments: [profileID])
        }
        return try String.fetchSet(db, sql: """
            SELECT id FROM account WHERE NOT EXISTS(SELECT 1 FROM pendingAccountRemoval r WHERE r.accountID = account.id)
            """)
    }

    static func initializedTodayAccounts(_ db: Database, scope: TodayScope) throws -> Set<String> {
        try String.fetchSet(db, sql: "SELECT accountID FROM todayVisit WHERE scopeKey = ?", arguments: [scope.storageKey])
    }

    static func validateTodayCapture(_ entries: [CommitmentEntry], accountIDs: Set<String>) throws {
        guard Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ accountIDs.contains($0.record.accountID) && $0.record.revision > 0 }) else {
            throw TodayVisitStoreError.invalidSnapshot
        }
    }

    static func matchesCurrentTodayContent(_ captured: CommitmentEntry, current: CommitmentEntry?) -> Bool {
        guard let current, captured.record.revision <= current.record.revision else { return false }
        // Notification acknowledgements advance the aggregate revision without changing the briefing.
        return TodayCommitmentSnapshot(entry: captured) == TodayCommitmentSnapshot(entry: current)
    }

    static func writeTodaySnapshot(_ db: Database, scope: TodayScope, entry: CommitmentEntry, now: Date) throws -> Bool {
        let payload = String(decoding: try JSONEncoder().encode(TodayCommitmentSnapshot(entry: entry)), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO todaySeenCommitment(scopeKey,accountID,commitmentID,snapshot,recordRevision,seenAt) VALUES (?,?,?,?,?,?)
            ON CONFLICT(scopeKey,accountID,commitmentID) DO UPDATE SET
                snapshot=excluded.snapshot,recordRevision=excluded.recordRevision,seenAt=MAX(seenAt,excluded.seenAt)
            WHERE excluded.recordRevision >= todaySeenCommitment.recordRevision
            """, arguments: [scope.storageKey, entry.record.accountID, entry.record.id, payload, entry.record.revision, now])
        return db.changesCount > 0
    }
}
