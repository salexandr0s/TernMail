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
        observe(region: ObservedTables.labels) { db in try CacheTransaction(db: db).displayedLabels(accountID: accountID) }
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
        // No account means no read, so there is no table to follow.
        guard !accountIDs.isEmpty else { return observe(region: []) { _ in [] } }
        let sql = ThreadListQuery.sql(accountCount: accountIDs.count)
        let arguments = ThreadListQuery.arguments(accountIDs: accountIDs, labelID: labelID, limit: limit)
        return observe(region: ObservedTables.threadList) { db in try ThreadRecord.fetchAll(db, sql: sql, arguments: arguments) }
    }

    /// The account's conversations for a caller that wants them once and
    /// doesn't follow them, as Spotlight indexing does: those under the
    /// first of `labelIDs`, then those under each later label that aren't
    /// listed yet, newest first within a label and up to `limit` in all.
    /// The labels are read from one snapshot on a reader connection.
    public func threadsListed(accountID: String, underEachOf labelIDs: [String], limit: Int) async throws -> [ThreadRecord] {
        let sql = ThreadListQuery.sql(accountCount: 1)
        return try await read { tx in
            var threads: [ThreadRecord] = []
            var seen = Set<String>()
            for labelID in labelIDs where threads.count < limit {
                let arguments = ThreadListQuery.arguments(accountIDs: [accountID], labelID: labelID, limit: limit)
                for thread in try ThreadRecord.fetchAll(tx.db, sql: sql, arguments: arguments)
                where threads.count < limit && seen.insert(thread.id).inserted {
                    threads.append(thread)
                }
            }
            return threads
        }
    }

    /// A mailbox's newest `limit` conversations under `labelID` across the
    /// accounts and the messages they show, read together as one page.
    public func listPage(accountIDs: [String], labelID: String, limit: Int) -> AsyncThrowingStream<MailListPage, any Error> {
        listPage(.mailbox(accountIDs: accountIDs, labelID: labelID, limit: limit))
    }

    /// The page `builder` describes, read again after each write that
    /// changes it. A write that leaves the page as it was sends nothing.
    public func listPage(_ builder: MailListPageBuilder) -> AsyncThrowingStream<MailListPage, any Error> {
        observe(latestOnly: true, region: ObservedTables.listPage(builder)) { db in try builder.page(in: CacheTransaction(db: db)) }
    }

    /// A conversation as the reader shows it. Its labels are the stored
    /// effective labels, so a queue row that changes state without changing
    /// a label wakes no reader.
    public func thread(accountID: String, threadID: String) -> AsyncThrowingStream<ThreadDetail?, any Error> {
        observe(region: ObservedTables.threadDetail) { db in
            try CacheTransaction(db: db).threadDetail(threadID: threadID, accountID: accountID)
        }
    }

    /// Drafts and sends that haven't reached Gmail, oldest first.
    public func outbox(accountID: String) -> AsyncThrowingStream<[DraftActivity], any Error> {
        observe(region: ObservedTables.drafts) { db in
            let transaction = CacheTransaction(db: db)
            return try transaction.localDrafts(accountID: accountID)
                .map { try transaction.draftActivity($0) }
                .filter(\.isOutgoing)
        }
    }

    /// One local draft and its queue rows, or nil once it is gone.
    public func draftActivity(localDraftID: String) -> AsyncThrowingStream<DraftActivity?, any Error> {
        observe(region: ObservedTables.drafts) { db in
            let transaction = CacheTransaction(db: db)
            return try transaction.localDraft(id: localDraftID).map(transaction.draftActivity)
        }
    }

    /// Addresses in cached mail whose name or address contains `text`, for
    /// completing a recipient. Case and accents don't matter. Prefix matches
    /// come first, then the addresses seen most often, then the most recent.
    public func addressSuggestions(
        accountID: String, matching text: String, excluding excluded: Set<String> = [], limit: Int = 8
    ) async throws -> [EmailAddress] {
        let query = SearchFolding.folded(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let headerRows = try await writer.read { db -> [[String?]] in
            // A message cached before `address-search-v1` has an empty column
            // until SyncEngine folds it (`foldPendingAddresses`), so it's
            // folded here until then.
            let rows = try Row.fetchCursor(db, sql: """
                SELECT sender, recipients, cc, addressSearch = '' AS pending FROM message
                WHERE accountID = :account AND (addressSearch LIKE :pattern ESCAPE '\\' OR addressSearch = '')
                ORDER BY date DESC
                """, arguments: ["account": accountID, "pattern": "%\(escaped)%"])
            var headers: [[String?]] = []
            while headers.count < 500, let row = try rows.next() {
                let sender: String = row["sender"], recipients: String = row["recipients"], cc: String? = row["cc"]
                if row["pending"], !SearchFolding.addresses(sender: sender, recipients: recipients, cc: cc).contains(query) {
                    continue
                }
                headers.append([sender, recipients, cc])
            }
            return headers
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
                let foldedKey = SearchFolding.folded(key)
                let name = SearchFolding.folded(address.name ?? "")
                guard foldedKey.contains(query) || name.contains(query) else { continue }
                if var candidate = candidates[key] {
                    candidate.count += 1
                    if candidate.address.name == nil { candidate.address.name = address.name }
                    candidates[key] = candidate
                } else {
                    let words = name.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "." })
                    let isPrefix = foldedKey.hasPrefix(query) || words.contains { $0.hasPrefix(query) }
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

    /// `fetch`'s value, and its value again after each write that changes it.
    ///
    /// `region` names every table `fetch` can read (`ObservedTables`). After
    /// a write to one of them has committed, the cache reads the value again
    /// on a reader connection, so no other write waits for the read. A table
    /// missing from `region` is a change the stream never shows.
    ///
    /// `region` has no default on purpose. Without the tables, GRDB records
    /// them from each read and has to read again on the writer inside the
    /// commit, where every other write waits for it. An in-memory cache has
    /// one connection and gives the same values.
    func observe<T: Sendable & Equatable>(
        latestOnly: Bool = false,
        region: [String],
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> AsyncThrowingStream<T, any Error> {
        let values = ValueObservation.tracking(regions: region.map { Table($0) }, fetch: fetch)
            .removeDuplicates().values(in: writer)
        // Large UI snapshots replace previous state. A slow renderer should
        // catch up to the newest page, not retain and prepare every sync step.
        // Event-like consumers keep the default lossless delivery.
        return AsyncThrowingStream(bufferingPolicy: latestOnly ? .bufferingNewest(1) : .unbounded) { continuation in
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

/// The tables each observed read can touch, for `MailCache.observe`. A list
/// holds every branch of its read, since a read that returns early touches
/// fewer. `MessageListEntryTests` compares each list whose read has more
/// than one statement with what the read records. The others name the
/// tables of the one statement beside them.
enum ObservedTables {
    /// `displayedLabels`.
    static let labels = ["label", "pendingAction"]
    /// `ThreadListQuery`.
    static let threadList = ["threadLabel", "thread"]
    /// `threadDetail`.
    static let threadDetail = ["thread", "message", "effectiveLabel", "messageBody", "attachment", "draft", "localDraft", "messageLabel"]
    /// `draftActivity`, for one draft or the Outbox.
    static let drafts = ["localDraft", "pendingAction", "outgoingAttachment"]
    /// `pendingChangeSummary`, and the failed rows of `failedActions`.
    static let pendingChanges = ["pendingAction"]
    /// `unreadCounts`.
    static let unreadCounts = ["unreadDelta", "label"]
    /// `threadLabels`: the displayed labels, the queue, the drafts a send
    /// hides, then each message's labels.
    static let threadLabels = labels + ["localDraft", "draft", "message", "messageLabel"]
    /// `searchThreads`. A query that can't run locally reads only `thread`.
    static let searchThreads = ["thread", "message", "messageText", "messageSearch", "messageLabel", "label"]
    /// `snoozedThreads`.
    static let snoozedThreads = ["cacheHold", "messageSnoozeHold", "thread"]
    /// `wokenThreadIDs`.
    static let wokenThreads = ["wokenThread"]
    /// `calendarInvitationState`.
    static let calendarInvitations = ["messageCalendar", "invitationReply"]
    /// `mimeResources`.
    static let readingResources = ["mimeResource"]
    /// `readReceiptStatuses`, for one message or a list.
    static let readReceipts = ["readReceiptRequest", "readReceiptRecipient", "readReceiptEvent"]
    /// `contactPhoto`.
    static let contactPhoto = ["contactPhoto", "contactEmail"]
    /// `newsletters`. Only the scan state is read until a scan has begun.
    static let newsletters = ["newsletterScanState", "newsletterMessage", "newsletterOutcome"]
    /// `attachmentLibrary`. The labels are read for a label filter.
    static let attachmentLibrary = ["attachmentLibrary", "attachmentLibraryLabel"]
    /// `attachmentIndexStates`.
    static let attachmentIndexStates = ["attachmentIndexState"]

    /// `mailAnalytics`. Bodies are read only for one sender's profile, so
    /// the window for every sender isn't read again as bodies arrive.
    static func mailAnalytics(_ query: MailAnalyticsQuery) -> [String] {
        let tables = ["mailAnalyticsMessage", "mailAnalyticsContact", "ownAddress", "mailAnalyticsState"]
        return query.contactAddress == nil ? tables : tables + ["messageBody"]
    }

    /// `messageListEntries`. Snooze holds are read for the snoozed list, and
    /// labels and search text for a query.
    static func messageList(matching query: SearchQuery?, snoozedOnly: Bool) -> [String] {
        var tables = ["message", "effectiveLabel", "attachment", "localDraft", "draft", "messageLabel"]
        if snoozedOnly { tables += ["cacheHold", "messageSnoozeHold"] }
        if query != nil { tables += ["label", "messageText", "messageSearch"] }
        return tables
    }

    /// `MailListPageBuilder.page`: the conversations, then their messages.
    static func listPage(_ builder: MailListPageBuilder) -> [String] {
        threadList + messageList(matching: builder.query, snoozedOnly: builder.snoozedOnly)
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
        try AccountStore(writer: DatabaseQueue(path: url.path(percentEncoded: false), configuration: .sharedFile))
    }

    public static func inMemory() throws -> AccountStore {
        try AccountStore(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.configMigrator.migrate(writer)
    }

    public func accounts() async throws -> [AccountRecord] {
        try await writer.read { db in
            try AccountRecord.fetchAll(db, sql: """
                SELECT account.* FROM account
                WHERE NOT EXISTS (SELECT 1 FROM pendingAccountRemoval p WHERE p.accountID = account.id)
                ORDER BY addedAt
                """)
        }
    }

    public func save(_ account: AccountRecord) async throws {
        try await writer.write { db in
            let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pendingAccountRemoval WHERE accountID = ?)",
                arguments: [account.id]) ?? false
            guard !pending else { throw AccountRemovalError.incomplete }
            try account.upsert(db)
        }
    }

    public func deleteAccount(id: String) async throws {
        try await writer.write { db in _ = try AccountRecord.deleteOne(db, key: id) }
    }
}

extension CacheTransaction {
    /// What `MailCache.thread(accountID:threadID:)` observes.
    func threadDetail(threadID: String, accountID: String) throws -> ThreadDetail? {
        guard let thread = try ThreadRecord.fetchOne(db, key: ["accountID": accountID, "id": threadID]) else {
            return nil
        }
        let labels = try storedEffectiveLabels(threadID: threadID, accountID: accountID)
        let bodies = try MessageBodyRecord
            .filter(Column("accountID") == accountID)
            .joining(required: MessageBodyRecord.message.filter(Column("threadID") == threadID))
            .fetchAll(db)
        let bodiesByID = Dictionary(bodies.map { ($0.messageID, $0) }, uniquingKeysWith: { first, _ in first })
        let hidden = try hiddenDraftMessageIDs(accountID: accountID)
        let records = try messages(threadID: threadID, accountID: accountID).filter { !hidden.contains($0.id) }
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

    func draftActivity(_ draft: LocalDraft) throws -> DraftActivity {
        DraftActivity(
            draft: draft,
            rows: try composeRows(localDraftID: draft.id),
            attachments: try outgoingAttachments(localDraftID: draft.id)
        )
    }

    /// Which of `ids` the account has cached, looked up by key 400 at a
    /// time. A sync that asks about the few messages a history page names
    /// uses this instead of `cachedMessageIDs(accountID:)`, which loads every
    /// cached ID.
    public func cachedMessageIDs(among ids: some Collection<String>, accountID: String) throws -> Set<String> {
        let ids = Array(ids)
        var cached = Set<String>()
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = ids[start..<min(start + 400, ids.count)]
            cached.formUnion(try String.fetchSet(
                db,
                sql: "SELECT id FROM message WHERE accountID = ? AND id IN (\(databaseQuestionMarks(count: chunk.count)))",
                arguments: StatementArguments([accountID] + chunk)
            ))
        }
        return cached
    }

    /// Folds the addresses of up to `limit` messages of the account that
    /// were cached before `address-search-v1`, the first ones after row
    /// `rowID`. Returns the last row folded, to continue after, or nil once
    /// none are left. Folded text always holds the line breaks between the
    /// headers, so an empty column marks a message still to fold.
    public func foldPendingAddresses(accountID: String, after rowID: Int64, limit: Int) throws -> Int64? {
        // `message_address_pending` holds only these messages, in row order,
        // so a write reads the ones it folds and nothing else.
        let rows = try Row.fetchAll(db, sql: """
            SELECT rowid, sender, recipients, cc FROM message
            WHERE accountID = ? AND addressSearch = '' AND rowid > ?
            ORDER BY rowid LIMIT ?
            """, arguments: [accountID, rowID, limit])
        let update = try db.cachedStatement(sql: "UPDATE message SET addressSearch = ? WHERE rowid = ?")
        for row in rows {
            let text = SearchFolding.addresses(sender: row["sender"], recipients: row["recipients"], cc: row["cc"])
            try update.execute(arguments: [text, row["rowid"]])
        }
        return rows.last?["rowid"]
    }
}
