import Foundation
import GRDB
import MessageContent

/// One message in the thread view.
public struct MessageDetail: Sendable, Equatable, Identifiable {
    public var record: MessageRecord
    /// Server labels with pending actions overlaid.
    public var labels: Set<String>
    public var body: MessageBodyRecord?
    public var attachments: [AttachmentRecord] = []
    /// The Gmail draft this message holds, for Edit Draft.
    public var draftID: String?

    public var id: String { record.id }
    public var isUnread: Bool { labels.contains(SystemLabel.unread) }
    public var isStarred: Bool { labels.contains(SystemLabel.starred) }

    /// Bodies compare by fetch, not by text: a body only changes when it is
    /// fetched again, and comparing the HTML of every message on each
    /// observation value is what made large conversations slow to open.
    public static func == (lhs: MessageDetail, rhs: MessageDetail) -> Bool {
        lhs.record == rhs.record && lhs.labels == rhs.labels && lhs.attachments == rhs.attachments
            && lhs.draftID == rhs.draftID && MessageBodyRecord.sameFetch(lhs.body, rhs.body)
    }
}

public struct ThreadDetail: Sendable, Equatable {
    public var thread: ThreadRecord
    public var messages: [MessageDetail]
}

/// A local draft with its queue rows, for the Outbox and the compose window's status.
public struct DraftActivity: Sendable, Equatable, Identifiable {
    public var draft: LocalDraft
    /// Oldest first.
    public var rows: [PendingAction]
    public var attachments: [OutgoingAttachment]

    public var id: String { draft.id }

    /// A send waiting out its delay, or under way.
    public var isSending: Bool { draft.state == .sending }

    /// Whether a save or send failed and waits to try again.
    public var isWaitingToRetry: Bool {
        rows.contains { $0.state == .queued && $0.lastError != nil }
    }

    /// Belongs in the Outbox: on its way out, refused, or unable to reach Gmail.
    public var isOutgoing: Bool {
        draft.state != .discarding && (isSending || draft.sendError != nil || isWaitingToRetry)
    }
}

extension MailCache {
    /// Labels as the sidebar and pickers show them: Gmail's last list with
    /// queued label changes applied. A label Gmail hasn't created yet has a
    /// temporary ID (`LabelRules.isTemporary`).
    public func labels(accountID: String) -> AsyncThrowingStream<[LabelRecord], any Error> {
        observe { db in try CacheTransaction(db: db).displayedLabels(accountID: accountID) }
    }

    /// Threads listed under `labelID`, newest first. A conversation a snooze
    /// brought back counts as new from its wake time.
    public func threads(accountID: String, labelID: String, limit: Int) -> AsyncThrowingStream<[ThreadRecord], any Error> {
        threads(accountIDs: [accountID], labelID: labelID, limit: limit)
    }

    /// Threads listed under `labelID` in any of the accounts, as one list for
    /// a combined mailbox. Each account's rows come off `threadLabel_list` in
    /// order and SQLite merges them, so no account is read past the page.
    public func threads(accountIDs: [String], labelID: String, limit: Int) -> AsyncThrowingStream<[ThreadRecord], any Error> {
        guard !accountIDs.isEmpty else { return observe { _ in [] } }
        let sql = ThreadListQuery.sql(accountCount: accountIDs.count)
        let arguments = ThreadListQuery.arguments(accountIDs: accountIDs, labelID: labelID, limit: limit)
        return observe { db in try ThreadRecord.fetchAll(db, sql: sql, arguments: arguments) }
    }

    public func thread(accountID: String, threadID: String) -> AsyncThrowingStream<ThreadDetail?, any Error> {
        observe { db in
            guard let thread = try ThreadRecord.fetchOne(db, key: ["accountID": accountID, "id": threadID]) else {
                return nil
            }
            let transaction = CacheTransaction(db: db)
            let labels = try transaction.effectiveLabels(
                threadID: threadID,
                accountID: accountID,
                actions: transaction.pendingActions(accountID: accountID)
            )
            let bodies = try MessageBodyRecord
                .filter(Column("accountID") == accountID)
                .joining(required: MessageBodyRecord.message.filter(Column("threadID") == threadID))
                .fetchAll(db)
            let bodiesByID = Dictionary(bodies.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })
            let hidden = try transaction.hiddenDraftMessageIDs(accountID: accountID)
            let records = try transaction.messages(threadID: threadID, accountID: accountID)
                .filter { !hidden.contains($0.id) }
            let messageIDs = records.map(\.id)
            let attachments = Dictionary(grouping: try AttachmentRecord
                .filter(Column("accountID") == accountID && messageIDs.contains(Column("messageID")))
                .order(Column.rowID) // payload order, as stored
                .fetchAll(db), by: \.messageID)
            let draftIDs = Dictionary(
                try DraftRecord
                    .filter(Column("accountID") == accountID && messageIDs.contains(Column("messageID")))
                    .fetchAll(db)
                    .map { ($0.messageID, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            let messages = records.map { record in
                MessageDetail(
                    record: record,
                    labels: labels[record.id] ?? [],
                    body: bodiesByID[record.id],
                    attachments: attachments[record.id] ?? [],
                    draftID: draftIDs[record.id]
                )
            }
            return ThreadDetail(thread: thread, messages: messages)
        }
    }

    /// Drafts and sends that haven't reached Gmail, oldest first.
    public func outbox(accountID: String) -> AsyncThrowingStream<[DraftActivity], any Error> {
        observe { db in
            let transaction = CacheTransaction(db: db)
            return try transaction.localDrafts(accountID: accountID)
                .map { try transaction.draftActivity($0) }
                .filter(\.isOutgoing)
        }
    }

    /// One local draft and its queue rows, or nil once it is gone.
    public func draftActivity(localDraftID: String) -> AsyncThrowingStream<DraftActivity?, any Error> {
        observe { db in
            let transaction = CacheTransaction(db: db)
            return try transaction.localDraft(id: localDraftID).map(transaction.draftActivity)
        }
    }

    /// Addresses in cached mail whose name or address contains `text`, for
    /// completing a recipient. Prefix matches come first, then the addresses
    /// seen most often, then the most recent.
    public func addressSuggestions(
        accountID: String, matching text: String, excluding excluded: Set<String> = [], limit: Int = 8
    ) async throws -> [EmailAddress] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let headerRows = try await writer.read { db -> [[String?]] in
            try Row.fetchAll(db, sql: """
                SELECT sender, recipients, cc FROM message
                WHERE accountID = :account
                  AND (sender LIKE :pattern ESCAPE '\\' OR recipients LIKE :pattern ESCAPE '\\' OR cc LIKE :pattern ESCAPE '\\')
                ORDER BY date DESC
                LIMIT 500
                """, arguments: ["account": accountID, "pattern": "%\(escaped)%"])
            .map { [$0["sender"], $0["recipients"], $0["cc"]] }
        }
        struct Candidate {
            var address: EmailAddress
            var isPrefix: Bool
            var count: Int
            var firstSeen: Int
        }
        var candidates: [String: Candidate] = [:]
        for (index, headers) in headerRows.enumerated() {
            for address in headers.compactMap({ $0 }).flatMap(EmailAddress.parseList) {
                let key = address.normalized
                guard address.isValid, !excluded.contains(key) else { continue }
                let name = address.name?.lowercased() ?? ""
                guard key.contains(query) || name.contains(query) else { continue }
                if var candidate = candidates[key] {
                    candidate.count += 1
                    if candidate.address.name == nil { candidate.address.name = address.name }
                    candidates[key] = candidate
                } else {
                    let words = name.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." })
                    let isPrefix = key.hasPrefix(query) || words.contains { $0.hasPrefix(query) }
                    candidates[key] = Candidate(address: address, isPrefix: isPrefix, count: 1, firstSeen: index)
                }
            }
        }
        return candidates.values
            .sorted { a, b in
                if a.isPrefix != b.isPrefix { return a.isPrefix }
                if a.count != b.count { return a.count > b.count }
                return a.firstSeen < b.firstSeen
            }
            .prefix(limit)
            .map(\.address)
    }

    public func syncState(accountID: String) async throws -> SyncStateRecord? {
        try await writer.read { db in try SyncStateRecord.fetchOne(db, key: accountID) }
    }

    func observe<T: Sendable & Equatable>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> AsyncThrowingStream<T, any Error> {
        let values = ValueObservation.tracking(fetch).removeDuplicates().values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension MessageBodyRecord {
    static let message = belongsTo(
        MessageRecord.self,
        using: ForeignKey(["accountID", "messageID"], to: ["accountID", "id"])
    )

    /// Whether two bodies are the same fetch, judged without reading the text.
    static func sameFetch(_ lhs: MessageBodyRecord?, _ rhs: MessageBodyRecord?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.fetchedAt == rhs.fetchedAt
                && lhs.html?.utf8.count == rhs.html?.utf8.count
                && lhs.plainText?.utf8.count == rhs.plainText?.utf8.count
        default:
            return false
        }
    }
}

/// The thread list's SQL: one arm per account, each ordered by the list
/// index, merged by SQLite. Accounts are sorted so ties between them fall
/// the same way every time.
enum ThreadListQuery {
    static func sql(accountCount: Int) -> String {
        let arm = """
            SELECT thread.*, threadLabel.listDate AS listDate, threadLabel.threadID AS sortID
            FROM threadLabel
            JOIN thread ON thread.accountID = threadLabel.accountID AND thread.id = threadLabel.threadID
            WHERE threadLabel.accountID = ? AND threadLabel.labelID = ?
            """
        let arms = Array(repeating: arm, count: accountCount).joined(separator: "UNION ALL\n")
        return arms + "ORDER BY listDate DESC, sortID LIMIT ?"
    }

    static func arguments(accountIDs: [String], labelID: String, limit: Int) -> StatementArguments {
        var arguments = StatementArguments()
        for accountID in accountIDs.sorted() {
            arguments += [accountID, labelID]
        }
        arguments += [limit]
        return arguments
    }
}

/// Account settings that survive a cache reset (`config.sqlite`).
public struct AccountStore: Sendable {
    let writer: any DatabaseWriter

    public static func open(at url: URL) throws -> AccountStore {
        try AccountStore(writer: DatabaseQueue(path: url.path(percentEncoded: false)))
    }

    public static func inMemory() throws -> AccountStore {
        try AccountStore(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.configMigrator.migrate(writer)
    }

    public func accounts() async throws -> [AccountRecord] {
        try await writer.read { db in try AccountRecord.order(Column("addedAt")).fetchAll(db) }
    }

    public func save(_ account: AccountRecord) async throws {
        try await writer.write { db in try account.upsert(db) }
    }

    public func deleteAccount(id: String) async throws {
        try await writer.write { db in _ = try AccountRecord.deleteOne(db, key: id) }
    }
}

extension CacheTransaction {
    func draftActivity(_ draft: LocalDraft) throws -> DraftActivity {
        DraftActivity(
            draft: draft,
            rows: try composeRows(localDraftID: draft.id),
            attachments: try outgoingAttachments(localDraftID: draft.id)
        )
    }
}
