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

    /// File compaction is separate because VACUUM cannot run inside the reset
    /// transaction. VACUUM rewrites the file through the log, so a truncating
    /// checkpoint follows. While a reader still uses the log it stays, and
    /// `journal_size_limit` cuts it back at a later checkpoint.
    public func compactDisposableCache() async throws {
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            do { try db.checkpoint(.truncate) } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {}
        }
    }

    /// `databaseBytes` counts the pages in use and the log frames SQLite
    /// hasn't copied into the database yet. Free pages are left out, since
    /// SQLite fills them before it grows the file. A passive checkpoint first
    /// copies every frame no reader still uses. After a compaction that a
    /// reader kept from emptying the log, the log file keeps the size of the
    /// whole database until a later write cuts it back to
    /// `journal_size_limit`, and counting the file made the next trim evict
    /// again.
    public func disposableContentUsage() async throws -> CacheUsage {
        let log = try await writer.writeWithoutTransaction { try $0.checkpoint(.passive) }
        return try await writer.read { db in
            let pages = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let free = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let size = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let bodies = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes),0) FROM messageBodySize") ?? 0
            let resources = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(data)),0) FROM mimeResource") ?? 0
            // Each frame holds a page and a 24-byte header.
            let frames = Int64(log.walFrameCount - log.checkpointedFrameCount)
            return CacheUsage(databaseBytes: (pages - free) * size + frames * (size + 24), bodyBytes: bodies, resourceBytes: resources)
        }
    }

    /// Every thread a trim may consider, least recently opened first. A pass
    /// reads this once: each eviction rechecks only the threads it's given.
    public func evictionCandidates(keeping: Set<CacheThreadReference>, now: Date) async throws -> [CacheEvictionCandidate] {
        try await read { try CacheMaintenanceSQL.candidates(tx: $0, keeping: keeping, now: now) }
    }

    /// Candidates are advisory. Each thread given is checked again in this
    /// write for holds, drafts and actions it gained since it was listed.
    public func evictContent(for threads: [CacheThreadReference], keeping: Set<CacheThreadReference>, now: Date) async throws -> CacheEvictionResult {
        try await write { tx in
            let rules = try CacheMaintenanceSQL.Rules(tx: tx, keeping: keeping, now: now)
            var result = CacheEvictionResult()
            for thread in threads.removingDuplicateReferences() {
                let state = try rules.state(of: thread, in: tx)
                guard !state.isProtected else { continue }
                let messages = try tx.messages(threadID: thread.threadID, accountID: thread.accountID).map(\.id)
                guard !messages.isEmpty else { continue }
                result.releasedContentBytes += state.disposableBytes
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
            let rules = try CacheMaintenanceSQL.Rules(tx: tx, keeping: keeping, now: now)
            var result = CacheEvictionResult()
            for thread in threads.removingDuplicateReferences() {
                let state = try rules.state(of: thread, in: tx)
                guard !state.isProtected, !state.keepsMetadata else { continue }
                guard try !CacheMaintenanceSQL.keepsInvitation(thread, tx: tx) else { continue }
                let messages = try tx.messages(threadID: thread.threadID, accountID: thread.accountID).map(\.id)
                guard !messages.isEmpty else { continue }
                result.releasedContentBytes += state.disposableBytes
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
    /// What eviction knows of one thread.
    struct ThreadState {
        var isProtected: Bool
        /// Whether it has mail full sync would only fetch again: from the
        /// last 30 days, or in the Inbox or Drafts.
        var keepsMetadata: Bool
        var disposableBytes: Int64
    }

    /// The protection rules, read once for a listing or an eviction. Both go
    /// through `state(of:in:)`, so a recheck can't disagree with the list.
    struct Rules {
        /// Threads the caller keeps, and those a change in the queue names.
        let kept: Set<CacheThreadReference>
        let arguments: StatementArguments

        init(tx: CacheTransaction, keeping: Set<CacheThreadReference>, now: Date) throws {
            guard now.timeIntervalSince1970.isFinite else { throw CacheMaintenanceError.invalidDate }
            var kept = keeping
            // Failed intent is recoverable too, even though it no longer contributes an optimistic overlay.
            for action in try PendingAction.fetchAll(tx.db, sql: "SELECT * FROM pendingAction WHERE state != 'sent'") {
                for threadID in action.threadIDs { kept.insert(.init(accountID: action.accountID, threadID: threadID)) }
                for messageID in action.messageIDs {
                    if let message = try tx.message(id: messageID, accountID: action.accountID) {
                        kept.insert(.init(accountID: action.accountID, threadID: message.threadID))
                    }
                }
            }
            self.kept = kept
            arguments = [
                "cutoff": now.addingTimeInterval(-Double(CacheHolds.recentDays) * 86400),
                "inbox": SystemLabel.inbox, "draft": SystemLabel.draft, "localSend": LocalSend.idPrefix + "*",
            ]
        }

        /// One thread's state, read with indexed lookups of its own rows.
        func state(of thread: CacheThreadReference, in tx: CacheTransaction) throws -> ThreadState {
            let row = try Row.fetchOne(tx.db.cachedStatement(sql: Self.stateSQL),
                                       arguments: self.arguments + ["accountID": thread.accountID, "threadID": thread.threadID])
            let isHeld: Bool = row?["isHeld"] ?? true
            return ThreadState(isProtected: isHeld || kept.contains(thread), keepsMetadata: row?["keepsMetadata"] ?? true,
                               disposableBytes: row?["disposableBytes"] ?? 0)
        }

        /// Holds are search and snooze holds, local drafts in the thread or
        /// replying to one of its messages, and provisional sends, whose
        /// bodies Gmail can't give back.
        private static let stateSQL = """
            SELECT EXISTS(SELECT 1 FROM cacheHold WHERE accountID = :accountID AND threadID = :threadID)
                OR EXISTS(SELECT 1 FROM messageSnoozeHold WHERE accountID = :accountID AND threadID = :threadID)
                OR EXISTS(SELECT 1 FROM localDraft d WHERE d.accountID = :accountID AND (d.threadID = :threadID
                    OR EXISTS(SELECT 1 FROM message m WHERE m.accountID = d.accountID
                        AND m.id IN (d.sourceMessageID, d.savedMessageID) AND m.threadID = :threadID)))
                OR EXISTS(SELECT 1 FROM message WHERE accountID = :accountID AND threadID = :threadID AND id GLOB :localSend)
                AS isHeld,
            EXISTS(SELECT 1 FROM message m WHERE m.accountID = :accountID AND m.threadID = :threadID
                AND (m.date >= :cutoff OR EXISTS(SELECT 1 FROM messageLabel l
                    WHERE l.accountID = m.accountID AND l.messageID = m.id AND l.labelID IN (:inbox, :draft))))
                AS keepsMetadata,
            (SELECT COALESCE(SUM(s.bytes), 0) FROM message m
                JOIN messageBodySize s ON s.accountID = m.accountID AND s.messageID = m.id
                WHERE m.accountID = :accountID AND m.threadID = :threadID)
            + (SELECT COALESCE(SUM(length(r.data)), 0) FROM message m
                JOIN mimeResource r ON r.accountID = m.accountID AND r.messageID = m.id
                WHERE m.accountID = :accountID AND m.threadID = :threadID)
                AS disposableBytes
            """
    }

    static func candidates(tx: CacheTransaction, keeping: Set<CacheThreadReference>, now: Date) throws -> [CacheEvictionCandidate] {
        let rules = try Rules(tx: tx, keeping: keeping, now: now)
        let invitationMetadata = Set(try tx.newestInvitationSources().map(\.thread))
        var found: [CacheEvictionCandidate] = []
        for row in try Row.fetchAll(tx.db, sql: """
            SELECT t.accountID,t.id,o.lastOpenedAt FROM thread t LEFT JOIN threadOpened o
            ON o.accountID=t.accountID AND o.threadID=t.id
            ORDER BY COALESCE(o.lastOpenedAt,''),t.accountID,t.id
            """) {
            let thread = CacheThreadReference(accountID: row["accountID"], threadID: row["id"])
            guard !rules.kept.contains(thread) else { continue }
            let state = try rules.state(of: thread, in: tx)
            guard !state.isProtected else { continue }
            found.append(CacheEvictionCandidate(thread: thread, lastOpenedAt: row["lastOpenedAt"], disposableBytes: state.disposableBytes,
                canEvictMetadata: !state.keepsMetadata && !invitationMetadata.contains(thread)))
        }
        return found
    }

    /// Whether the thread holds the newest organizer version of an
    /// invitation. Most threads hold no invitation, which one lookup shows.
    static func keepsInvitation(_ thread: CacheThreadReference, tx: CacheTransaction) throws -> Bool {
        let hasInvitation = try Bool.fetchOne(tx.db, sql: """
            SELECT EXISTS(SELECT 1 FROM message m JOIN messageCalendar c ON c.accountID = m.accountID AND c.messageID = m.id
                WHERE m.accountID = ? AND m.threadID = ?)
            """, arguments: [thread.accountID, thread.threadID]) ?? true
        guard hasInvitation else { return false }
        return try tx.newestInvitationSources(accountID: thread.accountID).contains { $0.thread == thread }
    }
}

private extension Array where Element == CacheThreadReference {
    func removingDuplicateReferences() -> [CacheThreadReference] {
        var seen = Set<CacheThreadReference>()
        return filter { seen.insert($0).inserted }
    }
}
