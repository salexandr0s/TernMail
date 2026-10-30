import Foundation
import GRDB

public struct CacheResetReadiness: Codable, Sendable, Equatable {
    public var localDraftCount: Int
    public var activeActionCount: Int
    public var failedActionCount: Int
    public var canReset: Bool { localDraftCount == 0 && activeActionCount == 0 && failedActionCount == 0 }

    public init(localDraftCount: Int, activeActionCount: Int, failedActionCount: Int) {
        self.localDraftCount = localDraftCount; self.activeActionCount = activeActionCount; self.failedActionCount = failedActionCount
    }
}

public enum CacheMaintenanceError: Error, Sendable, Equatable { case recoverableWork(CacheResetReadiness), invalidDate }

public struct CacheUsage: Codable, Sendable, Equatable {
    public var databaseBytes: Int64
    public var bodyBytes: Int64
    public var resourceBytes: Int64
    public var downloadedAttachmentBytes: Int64
    public init(databaseBytes: Int64 = 0, bodyBytes: Int64 = 0, resourceBytes: Int64 = 0, downloadedAttachmentBytes: Int64 = 0) {
        self.databaseBytes = databaseBytes; self.bodyBytes = bodyBytes; self.resourceBytes = resourceBytes
        self.downloadedAttachmentBytes = downloadedAttachmentBytes
    }
}

public struct CacheThreadReference: Codable, Hashable, Sendable {
    public var accountID: String
    public var threadID: String
    public init(accountID: String, threadID: String) { self.accountID = accountID; self.threadID = threadID }
}

public struct CacheEvictionCandidate: Codable, Sendable, Equatable {
    public var thread: CacheThreadReference
    public var lastOpenedAt: Date?
    public var disposableBytes: Int64
    public var canEvictMetadata: Bool
    public init(thread: CacheThreadReference, lastOpenedAt: Date? = nil, disposableBytes: Int64 = 0, canEvictMetadata: Bool = false) {
        self.thread = thread; self.lastOpenedAt = lastOpenedAt; self.disposableBytes = disposableBytes; self.canEvictMetadata = canEvictMetadata
    }
}

public struct CacheEvictionResult: Codable, Sendable, Equatable {
    public var evictedThreads: [CacheThreadReference]
    public var releasedContentBytes: Int64
    public var deletedMessageCount: Int
    public var messageIDsByAccount: [String: [String]]
    public init(evictedThreads: [CacheThreadReference] = [], releasedContentBytes: Int64 = 0, deletedMessageCount: Int = 0,
                messageIDsByAccount: [String: [String]] = [:]) {
        self.evictedThreads = evictedThreads; self.releasedContentBytes = releasedContentBytes
        self.deletedMessageCount = deletedMessageCount; self.messageIDsByAccount = messageIDsByAccount
    }
}

extension MailCache {
    public func cacheResetReadiness() async throws -> CacheResetReadiness {
        try await read { try $0.cacheResetReadiness() }
    }

    /// Root stops every writer before calling; this transaction checks again before deleting anything.
    public func resetDisposableCache() async throws {
        try await write { tx in
            let readiness = try tx.cacheResetReadiness()
            guard readiness.canReset else { throw CacheMaintenanceError.recoverableWork(readiness) }
            for table in ["threadLabel", "threadOpened", "thread", "attachment", "mimeResource", "messageBody", "messageCalendar",
                          "messageLabel", "message", "messageText", "label", "syncState", "draft", "cacheHold", "labelAlias",
                          "wokenThread", "contactEmail", "contact", "contactSync", "invitationReply", "attachmentLibraryLabel",
                          "attachmentLibrary", "attachmentIndexState", "pendingAction", "outgoingAttachment", "localDraft"] {
                try tx.db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    /// File compaction is separate because VACUUM cannot run inside the reset transaction.
    public func compactDisposableCache() async throws { try await writer.vacuum() }

    public func disposableContentUsage() async throws -> CacheUsage {
        try await writer.read { db in
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let bodies = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(COALESCE(length(CAST(html AS BLOB)),0)+COALESCE(length(CAST(plainText AS BLOB)),0)),0) FROM messageBody") ?? 0
            let resources = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(data)),0) FROM mimeResource") ?? 0
            return CacheUsage(databaseBytes: pages * size, bodyBytes: bodies, resourceBytes: resources)
        }
    }

    public func evictionCandidates(keeping: Set<CacheThreadReference>, now: Date) async throws -> [CacheEvictionCandidate] {
        try await read { try CacheMaintenanceSQL.candidates(tx: $0, keeping: keeping, now: now) }
    }

    /// Candidates are advisory; current holds, drafts and actions are rechecked inside this write.
    public func evictContent(for threads: [CacheThreadReference], keeping: Set<CacheThreadReference>, now: Date) async throws -> CacheEvictionResult {
        try await write { tx in
            let eligible = Set(try CacheMaintenanceSQL.candidates(tx: tx, keeping: keeping, now: now).map(\.thread))
            var result = CacheEvictionResult()
            for thread in threads.removingDuplicateReferences() where eligible.contains(thread) {
                let messages = try tx.messages(threadID: thread.threadID, accountID: thread.accountID).map(\.id)
                guard !messages.isEmpty else { continue }
                result.releasedContentBytes += try CacheMaintenanceSQL.contentBytes(thread: thread, db: tx.db)
                for messageID in messages {
                    let args: StatementArguments = [thread.accountID, messageID]
                    try tx.db.execute(sql: "DELETE FROM messageBody WHERE accountID = ? AND messageID = ?", arguments: args)
                    try tx.db.execute(sql: "DELETE FROM mimeResource WHERE accountID = ? AND messageID = ?", arguments: args)
                    try tx.db.execute(sql: "UPDATE messageText SET body = NULL WHERE accountID = ? AND messageID = ?", arguments: args)
                }
                result.evictedThreads.append(thread)
                result.messageIDsByAccount[thread.accountID, default: []].append(contentsOf: messages)
            }
            return result
        }
    }

    public func evictMetadata(for threads: [CacheThreadReference], keeping: Set<CacheThreadReference>, now: Date) async throws -> CacheEvictionResult {
        try await write { tx in
            let eligible = Set(try CacheMaintenanceSQL.candidates(tx: tx, keeping: keeping, now: now).filter(\.canEvictMetadata).map(\.thread))
            var result = CacheEvictionResult()
            for thread in threads.removingDuplicateReferences() where eligible.contains(thread) {
                let messages = try tx.messages(threadID: thread.threadID, accountID: thread.accountID).map(\.id)
                guard !messages.isEmpty else { continue }
                result.releasedContentBytes += try CacheMaintenanceSQL.contentBytes(thread: thread, db: tx.db)
                let affected = try tx.deleteMessages(ids: messages, accountID: thread.accountID)
                try tx.rebuildThreads(affected, accountID: thread.accountID)
                result.deletedMessageCount += messages.count
                result.evictedThreads.append(thread)
                result.messageIDsByAccount[thread.accountID, default: []].append(contentsOf: messages)
            }
            return result
        }
    }
}

extension CacheTransaction {
    public func cacheResetReadiness() throws -> CacheResetReadiness {
        CacheResetReadiness(
            localDraftCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM localDraft") ?? 0,
            activeActionCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pendingAction WHERE state NOT IN ('sent','failed')") ?? 0,
            failedActionCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pendingAction WHERE state = 'failed'") ?? 0)
    }
}

enum CacheMaintenanceSQL {
    static func protectedThreads(tx: CacheTransaction, keeping: Set<CacheThreadReference>) throws -> Set<CacheThreadReference> {
        var protected = keeping
        for row in try Row.fetchAll(tx.db, sql: """
            SELECT accountID,threadID FROM cacheHold
            UNION SELECT accountID,threadID FROM messageSnoozeHold
            UNION SELECT accountID,threadID FROM localDraft WHERE threadID IS NOT NULL
            UNION SELECT m.accountID,m.threadID FROM message m JOIN localDraft d
                ON m.accountID=d.accountID AND m.id IN (d.sourceMessageID,d.savedMessageID)
            """) {
            protected.insert(CacheThreadReference(accountID: row["accountID"], threadID: row["threadID"]))
        }
        // Failed intent is recoverable too, even though it no longer contributes an optimistic overlay.
        for action in try PendingAction.fetchAll(tx.db, sql: "SELECT * FROM pendingAction WHERE state != 'sent'") {
            for threadID in action.threadIDs { protected.insert(.init(accountID: action.accountID, threadID: threadID)) }
            for messageID in action.messageIDs {
                if let message = try tx.message(id: messageID, accountID: action.accountID) {
                    protected.insert(.init(accountID: action.accountID, threadID: message.threadID))
                }
            }
        }
        return protected
    }

    static func candidates(tx: CacheTransaction, keeping: Set<CacheThreadReference>, now: Date) throws -> [CacheEvictionCandidate] {
        guard now.timeIntervalSince1970.isFinite else { throw CacheMaintenanceError.invalidDate }
        let protected = try protectedThreads(tx: tx, keeping: keeping)
        let invitationMetadata = Set(try tx.newestInvitationSources().map(\.thread))
        let cutoff = now.addingTimeInterval(-Double(CacheHolds.recentDays) * 86400)
        var found: [CacheEvictionCandidate] = []
        for row in try Row.fetchAll(tx.db, sql: """
            SELECT t.accountID,t.id,o.lastOpenedAt FROM thread t LEFT JOIN threadOpened o
            ON o.accountID=t.accountID AND o.threadID=t.id
            ORDER BY COALESCE(o.lastOpenedAt,''),t.accountID,t.id
            """) {
            let thread = CacheThreadReference(accountID: row["accountID"], threadID: row["id"])
            guard !protected.contains(thread) else { continue }
            let kept = try Bool.fetchOne(tx.db, sql: """
                SELECT EXISTS(SELECT 1 FROM message m WHERE m.accountID = ? AND m.threadID = ?
                    AND (m.date >= ? OR EXISTS(SELECT 1 FROM messageLabel l
                        WHERE l.accountID=m.accountID AND l.messageID=m.id AND l.labelID IN (?,?))))
                """, arguments: [thread.accountID, thread.threadID, cutoff, SystemLabel.inbox, SystemLabel.draft]) ?? true
            found.append(CacheEvictionCandidate(thread: thread, lastOpenedAt: row["lastOpenedAt"],
                disposableBytes: try contentBytes(thread: thread, db: tx.db), canEvictMetadata: !kept && !invitationMetadata.contains(thread)))
        }
        return found
    }

    static func contentBytes(thread: CacheThreadReference, db: Database) throws -> Int64 {
        let bodies = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(COALESCE(length(CAST(b.html AS BLOB)),0)+COALESCE(length(CAST(b.plainText AS BLOB)),0)),0)
            FROM messageBody b JOIN message m ON m.accountID=b.accountID AND m.id=b.messageID
            WHERE m.accountID = ? AND m.threadID = ?
            """, arguments: [thread.accountID, thread.threadID]) ?? 0
        let resources = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(length(r.data)),0) FROM mimeResource r
            JOIN message m ON m.accountID=r.accountID AND m.id=r.messageID WHERE m.accountID = ? AND m.threadID = ?
            """, arguments: [thread.accountID, thread.threadID]) ?? 0
        return bodies + resources
    }
}

private extension Array where Element == CacheThreadReference {
    func removingDuplicateReferences() -> [CacheThreadReference] {
        var seen = Set<CacheThreadReference>()
        return filter { seen.insert($0).inserted }
    }
}
