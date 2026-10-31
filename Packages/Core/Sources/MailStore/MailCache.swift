import Foundation
import GRDB

/// The message cache (`cache.sqlite`). A full sync can restore the mail in it,
/// but not local drafts or pending actions: resyncs keep those, and deleting
/// the file loses unsent work.
public struct MailCache: Sendable {
    let writer: any DatabaseWriter

    public static func open(at url: URL) throws -> MailCache {
        try MailCache(writer: DatabasePool(path: url.path(percentEncoded: false)))
    }

    public static func inMemory() throws -> MailCache {
        try MailCache(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.cacheMigrator.migrate(writer)
    }

    /// Runs `updates` in one write transaction.
    public func write<T: Sendable>(_ updates: @escaping @Sendable (CacheTransaction) throws -> T) async throws -> T {
        try await writer.write { db in try updates(CacheTransaction(db: db)) }
    }

    /// Runs `fetch` in a read-only transaction. Writing inside it throws.
    public func read<T: Sendable>(_ fetch: @escaping @Sendable (CacheTransaction) throws -> T) async throws -> T {
        try await writer.read { db in try fetch(CacheTransaction(db: db)) }
    }
}

/// Write access to the cache inside one transaction.
public struct CacheTransaction {
    let db: Database

    /// Removes everything cached for an account, including unsent actions,
    /// drafts, contacts and invitation answers. Outgoing attachment rows go
    /// with their local drafts, and search text with its messages.
    public func deleteAccountData(accountID: String) throws {
        for table in Self.accountTables {
            try db.execute(sql: "DELETE FROM \(table) WHERE accountID = ?", arguments: [accountID])
        }
    }

    /// Every account with rows in the cache, so a launch can remove the rows
    /// of accounts that were signed out.
    public func cachedAccountIDs() throws -> Set<String> {
        let union = Self.accountTables.map { "SELECT accountID FROM \($0)" }.joined(separator: " UNION ")
        return try Set(String.fetchAll(db, sql: union))
    }

    private static let accountTables = [
        "threadLabel", "thread", "attachment", "messageBody", "messageLabel", "messageCalendar", "message", "label",
        "pendingAction", "syncState", "draft", "localDraft", "cacheHold", "labelAlias", "wokenThread",
        "contactEmail", "contact", "contactSync", "invitationReply", "messageSnoozeHold",
        "attachmentLibrary", "attachmentLibraryLabel", "attachmentIndexState",
    ]

    // MARK: Labels

    /// Replaces the account's labels with `labels`.
    public func replaceLabels(_ labels: [LabelRecord], accountID: String) throws {
        for label in labels {
            try label.upsert(db)
        }
        let kept = labels.map(\.id)
        try LabelRecord
            .filter(Column("accountID") == accountID && !kept.contains(Column("id")))
            .deleteAll(db)
    }

    // MARK: Messages

    public struct MessageUpdate: Sendable {
        public var record: MessageRecord
        public var labelIDs: [String]

        public init(record: MessageRecord, labelIDs: [String]) {
            self.record = record
            self.labelIDs = labelIDs
        }
    }

    /// Stores messages with their server labels and returns the affected thread IDs.
    /// An update older than the stored copy (lower history ID) is ignored.
    @discardableResult
    public func upsertMessages(_ updates: [MessageUpdate]) throws -> Set<String> {
        var threads = Set<String>()
        for update in updates {
            let record = update.record
            if let stored = try MessageRecord.fetchOne(db, key: ["accountID": record.accountID, "id": record.id]) {
                guard stored.historyID <= record.historyID else { continue }
                threads.insert(stored.threadID)
            }
            try record.upsert(db)
            try updateLibraryMetadata(record, labelIDs: update.labelIDs)
            try db.execute(
                sql: "DELETE FROM messageLabel WHERE accountID = ? AND messageID = ?",
                arguments: [record.accountID, record.id]
            )
            for labelID in Set(update.labelIDs) {
                try db.execute(
                    sql: "INSERT INTO messageLabel (accountID, messageID, labelID) VALUES (?, ?, ?)",
                    arguments: [record.accountID, record.id, labelID]
                )
            }
            threads.insert(record.threadID)
        }
        return threads
    }

    /// Applies a history label change to a cached message and raises its stored
    /// history ID to the change's, so older metadata fetched later can't undo it.
    /// Returns the thread ID, or nil when the message is not cached.
    public func applyLabelChange(
        messageID: String, added: [String], removed: [String], historyID: Int64, accountID: String
    ) throws -> String? {
        try applyLibraryLabelChange(messageID: messageID, added: added, removed: removed, historyID: historyID, accountID: accountID)
        guard var message = try MessageRecord.fetchOne(db, key: ["accountID": accountID, "id": messageID]) else {
            return nil
        }
        guard historyID >= message.historyID else { return nil }
        if historyID > message.historyID {
            message.historyID = historyID
            try message.update(db)
        }
        for labelID in added {
            try db.execute(
                sql: "INSERT OR IGNORE INTO messageLabel (accountID, messageID, labelID) VALUES (?, ?, ?)",
                arguments: [accountID, messageID, labelID]
            )
        }
        for labelID in removed {
            try db.execute(
                sql: "DELETE FROM messageLabel WHERE accountID = ? AND messageID = ? AND labelID = ?",
                arguments: [accountID, messageID, labelID]
            )
        }
        return message.threadID
    }

    /// Deletes messages and returns the thread IDs they belonged to.
    @discardableResult
    public func deleteMessages(ids: some Collection<String>, accountID: String) throws -> Set<String> {
        var threads = Set<String>()
        for id in ids {
            if let message = try MessageRecord.fetchOne(db, key: ["accountID": accountID, "id": id]) {
                threads.insert(message.threadID)
                try message.delete(db)
            }
        }
        return threads
    }

    /// Deletes every message not in `kept`, except messages a pending action
    /// still targets and messages in held conversations. Used after a full
    /// resync. Returns the affected thread IDs.
    @discardableResult
    public func deleteMessages(notIn kept: Set<String>, accountID: String, through historyID: Int64? = nil) throws -> Set<String> {
        let protected = try messageIDsTargetedByPendingActions(accountID: accountID)
            .union(messageIDsInHeldThreads(accountID: accountID))
        var stale = try cachedMessageIDs(accountID: accountID).subtracting(kept).subtracting(protected)
        if let historyID {
            // A thread load can ingest new mail while the resync awaits its
            // listings. Those revisions postdate the held profile snapshot.
            let oldEnough = try String.fetchSet(db, MessageRecord.select(Column("id"))
                .filter(Column("accountID") == accountID && Column("historyID") <= historyID))
            stale.formIntersection(oldEnough)
        }
        return try deleteMessages(ids: stale, accountID: accountID)
    }

    /// Cached messages that a pending action names, directly or through its thread.
    public func messageIDsTargetedByPendingActions(accountID: String) throws -> Set<String> {
        let actions = try pendingActions(accountID: accountID)
        let threads = Array(Set(actions.flatMap(\.threadIDs)))
        let messages = Set(actions.flatMap(\.messageIDs))
        let inThreads = try String.fetchSet(
            db,
            MessageRecord
                .select(Column("id"))
                .filter(Column("accountID") == accountID && threads.contains(Column("threadID")))
        )
        return inThreads.union(messages.intersection(try cachedMessageIDs(accountID: accountID)))
    }

    public func cachedMessageIDs(accountID: String) throws -> Set<String> {
        try String.fetchSet(db, sql: "SELECT id FROM message WHERE accountID = ?", arguments: [accountID])
    }

    public func message(id: String, accountID: String) throws -> MessageRecord? {
        try MessageRecord.fetchOne(db, key: ["accountID": accountID, "id": id])
    }

    public func body(messageID: String, accountID: String) throws -> MessageBodyRecord? {
        try MessageBodyRecord.fetchOne(db, key: ["accountID": accountID, "messageID": messageID])
    }

    public func messages(threadID: String, accountID: String) throws -> [MessageRecord] {
        try MessageRecord
            .filter(Column("accountID") == accountID && Column("threadID") == threadID)
            .order(Column("date"), Column("id"))
            .fetchAll(db)
    }

    /// Messages in a thread whose body has not been fetched yet.
    public func messageIDsWithoutBody(threadID: String, accountID: String) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT message.id
            FROM message
            LEFT JOIN messageBody ON messageBody.accountID = message.accountID AND messageBody.messageID = message.id
            WHERE message.accountID = ? AND message.threadID = ? AND messageBody.messageID IS NULL
            """, arguments: [accountID, threadID])
    }

    public func thread(id: String, accountID: String) throws -> ThreadRecord? {
        try ThreadRecord.fetchOne(db, key: ["accountID": accountID, "id": id])
    }

    public func labels(accountID: String) throws -> [LabelRecord] {
        try LabelRecord.filter(Column("accountID") == accountID).fetchAll(db)
    }

    /// Stores bodies, search text and their parsed invitations together. Each
    /// supplied body replaces its calendar record, clearing it when absent.
    /// Calendar records without a matching account and message body are ignored.
    public func saveBodies(_ bodies: [MessageBodyRecord], calendars: [MessageCalendarRecord] = []) throws {
        var calendarsByAccount: [String: [String: MessageCalendarRecord]] = [:]
        for calendar in calendars {
            calendarsByAccount[calendar.accountID, default: [:]][calendar.messageID] = calendar
        }
        for body in bodies {
            try body.upsert(db)
            try indexBody(body)
            if let calendar = calendarsByAccount[body.accountID]?[body.messageID] {
                try saveMessageCalendar(calendar)
            } else {
                try MessageCalendarRecord.deleteOne(db, key: ["accountID": body.accountID, "messageID": body.messageID])
            }
        }
    }

    // MARK: Sync state

    public func syncState(accountID: String) throws -> SyncStateRecord? {
        try SyncStateRecord.fetchOne(db, key: accountID)
    }

    /// Stores the history cursor. The cursor only moves forward unless `reset`
    /// is set, which a full resync after an expired cursor needs.
    public func saveCursor(historyID: Int64, accountID: String, fullSyncAt: Date? = nil, reset: Bool = false) throws {
        if let stored = try syncState(accountID: accountID) {
            guard reset || historyID >= stored.historyID else { return }
            try SyncStateRecord(
                accountID: accountID,
                historyID: historyID,
                lastFullSyncAt: fullSyncAt ?? stored.lastFullSyncAt
            ).update(db)
        } else {
            try SyncStateRecord(accountID: accountID, historyID: historyID, lastFullSyncAt: fullSyncAt ?? .distantPast).insert(db)
        }
    }

    // MARK: Pending actions

    /// Records a local label change and rebuilds the affected threads so the UI
    /// shows it at once. The diff is taken against what the user currently sees.
    /// Nil when the change would alter no label the cache knows: nothing to
    /// show, send or undo. A deletion, or a message the cache has not seen,
    /// is never a no-op. Nor is a `compensating` change: it makes Gmail match
    /// the cache after a change Gmail may have applied, such as the inverse
    /// of an undone row, so it is queued whatever the cache shows.
    public func enqueue(
        _ kind: PendingAction.Kind,
        accountID: String,
        threadIDs: [String] = [],
        messageIDs: [String] = [],
        add: [String] = [],
        remove: [String] = [],
        now: Date,
        notBefore: Date,
        compensating: Bool = false
    ) throws -> PendingAction? {
        let existing = try pendingActions(accountID: accountID)
        var affectedThreads = Set(threadIDs)
        if !messageIDs.isEmpty {
            affectedThreads.formUnion(try threadIDsOf(messageIDs: messageIDs, accountID: accountID))
        }
        let messageScoped = [.modifyMessages, .trashMessages, .untrashMessages, .deleteMessages].contains(kind)

        var diff: [String: PendingAction.LabelDiff] = [:]
        var alreadyTrashed: [String] = []
        for threadID in affectedThreads {
            let labels = try effectiveLabels(threadID: threadID, accountID: accountID, actions: existing)
            let targets = messageScoped ? messageIDs.filter { labels[$0] != nil } : Array(labels.keys)
            for messageID in targets {
                let current = labels[messageID] ?? []
                if kind == .trashThreads, current.contains(SystemLabel.trash) { alreadyTrashed.append(messageID) }
                let change = PendingAction.LabelDiff(
                    added: add.filter { !current.contains($0) }.sorted(),
                    removed: remove.filter { current.contains($0) }.sorted()
                )
                // Empty diffs still record which messages were known when the
                // command was made; a sent change is overlaid on those alone.
                diff[messageID] = change
            }
        }
        let unknown = messageScoped ? messageIDs.filter { diff[$0] == nil } : []
        if !compensating, kind != .deleteMessages, !diff.isEmpty, unknown.isEmpty,
           diff.values.allSatisfy({ $0.added.isEmpty && $0.removed.isEmpty }) {
            return nil
        }

        var action = PendingAction(
            id: nil, accountID: accountID, kind: kind,
            threadIDs: threadIDs, messageIDs: kind == .trashThreads ? alreadyTrashed.sorted() : messageIDs,
            addLabelIDs: add, removeLabelIDs: remove, diff: diff,
            state: .queued, attempts: 0, lastError: nil,
            createdAt: now, notBefore: notBefore, sentAt: nil
        )
        try action.insert(db)
        try rebuildThreads(affectedThreads, accountID: accountID)
        return action
    }

    /// Queues a change to Gmail's settings. No conversation changes, so
    /// nothing is rebuilt.
    public func enqueueSettingsChange(
        _ change: PendingAction.SettingsChange, accountID: String, now: Date, notBefore: Date
    ) throws -> PendingAction {
        var row = PendingAction(
            id: nil, accountID: accountID, kind: change.kind,
            threadIDs: [], messageIDs: [], addLabelIDs: [], removeLabelIDs: [], diff: [:],
            state: .queued, attempts: 0, lastError: nil,
            createdAt: now, notBefore: notBefore, sentAt: nil,
            settingsChange: change
        )
        try row.insert(db)
        return row
    }

    public func pendingActions(accountID: String) throws -> [PendingAction] {
        try PendingAction.filter(Column("accountID") == accountID && Column("state") != PendingAction.State.failed.rawValue)
            .order(Column("id")).fetchAll(db)
    }

    public func allActions(accountID: String) throws -> [PendingAction] {
        try PendingAction.filter(Column("accountID") == accountID).order(Column("id")).fetchAll(db)
    }

    public func action(id: Int64) throws -> PendingAction? {
        try PendingAction.fetchOne(db, key: id)
    }

    /// Marks due actions in `lane` as `sending` and returns them, so two senders
    /// never pick up the same row. Changes reach Gmail in the order they were
    /// made: a row waits while an older unsent row holds one of its keys, even
    /// a row held back by a retry. See `claimKeys(of:)`.
    public func claimDueActions(accountID: String, now: Date, lane: PendingAction.Lane = .labels) throws -> [PendingAction] {
        var exclusive = Set<String>()
        var shared = Set<String>()
        var claimed: [PendingAction] = []
        for var action in try pendingActions(accountID: accountID) where action.state != .sent && action.kind.lane == lane {
            let keys = try claimKeys(of: action)
            if action.state == .queued, action.notBefore <= now,
               keys.exclusive.isDisjoint(with: exclusive), keys.exclusive.isDisjoint(with: shared),
               keys.shared.isDisjoint(with: exclusive) {
                action.state = .sending
                // A crash may happen after Gmail applies this attempt but before
                // its reply is saved. Undo must compensate after recovery.
                action.attempts += 1
                try action.update(db)
                claimed.append(action)
            }
            exclusive.formUnion(keys.exclusive)
            shared.formUnion(keys.shared)
        }
        return claimed
    }

    /// An exclusive key waits for every older row holding the key; a shared
    /// key waits only for older exclusive holders. A draft row holds its local
    /// draft and a label row its label, exclusively; a child's rename holds
    /// its parent's label too, shared, so it follows the parent's rename. A
    /// conversation row holds its threads exclusively and the labels it adds
    /// or removes shared, so one label goes onto many conversations together
    /// while a rename or delete of that label waits its turn. A settings row
    /// holds what it changes exclusively: every filter row one key, the
    /// vacation responder another, and each address's signature its own, so
    /// an undo goes out after the change it reverses.
    func claimKeys(of action: PendingAction) throws -> (exclusive: Set<String>, shared: Set<String>) {
        if let localDraftID = action.localDraftID { return (["draft:" + localDraftID], []) }
        if let change = action.settingsChange {
            let key = switch change {
            case .createFilter, .deleteFilter, .replaceFilter: "settings:filters"
            case .vacation: "settings:vacation"
            case .signature(let address, _, _): "settings:signature:" + address.lowercased()
            }
            return ([key], [])
        }
        if action.kind.changesLabel {
            let own = action.labelID.map { Set(["label:" + $0]) } ?? []
            let parent = action.labelChange?.parentLabelID.map { Set(["label:" + $0]) } ?? []
            return (own, parent)
        }
        let threads = try threadIDs(of: action).map { "thread:" + $0 }
        let messages = Set(action.messageIDs).union(action.diff.keys).map { "message:" + $0 }
        let labels = (action.addLabelIDs + action.removeLabelIDs).map { "label:" + $0 }
        return (Set(threads + messages), Set(labels))
    }

    /// Recovers rows a quit or crash left mid-send. `sending` rows go back in
    /// the queue (resending a label change is harmless) and `undone` rows are
    /// dropped, since their inverse is already queued.
    public func requeueInterruptedActions(accountID: String) throws {
        try db.execute(
            sql: "DELETE FROM pendingAction WHERE accountID = ? AND state = ?",
            arguments: [accountID, PendingAction.State.undone.rawValue]
        )
        try db.execute(
            sql: "UPDATE pendingAction SET state = ?, attempts = MAX(attempts, 1) WHERE accountID = ? AND state = ?",
            arguments: [PendingAction.State.queued.rawValue, accountID, PendingAction.State.sending.rawValue]
        )
    }

    public func updateAction(_ action: PendingAction) throws {
        try action.update(db)
    }

    /// Deletes the action if it is missing or was undone mid-send. Returns
    /// true when the caller should stop handling it.
    @discardableResult
    public func deleteActionIfUndone(id: Int64) throws -> Bool {
        guard let action = try action(id: id) else { return true }
        guard action.state == .undone else { return false }
        try deleteAction(id: id)
        return true
    }

    /// Removes an action and rebuilds its threads, which reverts it locally.
    public func deleteAction(id: Int64) throws {
        guard let action = try PendingAction.fetchOne(db, key: id) else { return }
        try action.delete(db)
        try rebuildThreads(try threadIDs(of: action), accountID: action.accountID)
    }

    /// Drops sent actions whose send finished before `date`, the start of a
    /// history pass that has since brought their effect into server state.
    /// A deleted label also comes off its messages again, since a pass that
    /// fetched before the delete reached Gmail may have stored it back.
    public func dropSentActions(sentBefore date: Date, accountID: String) throws {
        let sent = try PendingAction
            .filter(Column("accountID") == accountID && Column("state") == PendingAction.State.sent.rawValue)
            .fetchAll(db)
            .filter { ($0.sentAt ?? .distantFuture) < date }
        var threads = Set<String>()
        for action in sent {
            threads.formUnion(try threadIDs(of: action))
            try action.delete(db)
            if action.kind == .deleteLabel, let labelID = action.labelID {
                threads.formUnion(try threadIDsCarrying(labelID, accountID: accountID))
                try db.execute(sql: "DELETE FROM messageLabel WHERE accountID = ? AND labelID = ?", arguments: [accountID, labelID])
            }
        }
        try rebuildThreads(threads, accountID: accountID)
    }

    // MARK: Threads

    /// Rebuilds the derived `thread` and `threadLabel` rows from server labels
    /// with pending actions overlaid. Draft messages on their way out are left out.
    public func rebuildThreads(_ threadIDs: some Collection<String>, accountID: String) throws {
        guard !threadIDs.isEmpty else { return }
        let actions = try pendingActions(accountID: accountID)
        let hidden = try hiddenDraftMessageIDs(accountID: accountID)
        for threadID in Set(threadIDs) {
            let messages = try messages(threadID: threadID, accountID: accountID).filter { !hidden.contains($0.id) }
            try ThreadRecord.deleteOne(db, key: ["accountID": accountID, "id": threadID])
            guard let first = messages.first, let last = messages.last else {
                try forgetWake(threadID: threadID, accountID: accountID)
                continue
            }

            let labels = try effectiveLabels(threadID: threadID, accountID: accountID, actions: actions)
            let threadLabels = ThreadRules.threadLabels(messageLabels: messages.map { labels[$0.id] ?? [] })
            let allLabels = messages.reduce(into: Set<String>()) { $0.formUnion(labels[$1.id] ?? []) }

            let thread = ThreadRecord(
                accountID: accountID,
                id: threadID,
                lastDate: last.date,
                subject: messages.first { !$0.subject.isEmpty }?.subject ?? first.subject,
                snippet: last.snippet,
                participants: ThreadRules.participants(senders: messages.map(\.sender)),
                messageCount: messages.count,
                isUnread: allLabels.contains(SystemLabel.unread),
                isStarred: allLabels.contains(SystemLabel.starred)
            )
            try thread.insert(db)
            // A conversation a snooze brought back sorts by its wake time
            // until it leaves the Inbox.
            let wokeAt: Date?
            if threadLabels.contains(SystemLabel.inbox) {
                wokeAt = try wakeTime(threadID: threadID, accountID: accountID)
            } else {
                try forgetWake(threadID: threadID, accountID: accountID)
                wokeAt = nil
            }
            let listDate = max(last.date, wokeAt ?? last.date)
            for labelID in threadLabels {
                try ThreadLabelRecord(
                    accountID: accountID, threadID: threadID, labelID: labelID, lastDate: last.date, listDate: listDate
                ).insert(db)
            }
        }
    }

    /// Server labels per message in a thread, with `actions` applied in order.
    func effectiveLabels(threadID: String, accountID: String, actions: [PendingAction]) throws -> [String: Set<String>] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT message.id AS messageID, messageLabel.labelID AS labelID
            FROM message
            LEFT JOIN messageLabel ON messageLabel.accountID = message.accountID AND messageLabel.messageID = message.id
            WHERE message.accountID = ? AND message.threadID = ?
            """, arguments: [accountID, threadID])
        var labels: [String: Set<String>] = [:]
        for row in rows {
            let messageID: String = row["messageID"]
            let labelID: String? = row["labelID"]
            labels[messageID, default: []].formUnion(labelID.map { [$0] } ?? [])
        }
        ThreadRules.overlay(actions, onto: &labels, threadID: threadID)
        return labels
    }

    private func threadIDs(of action: PendingAction) throws -> Set<String> {
        Set(action.threadIDs).union(try threadIDsOf(messageIDs: action.messageIDs, accountID: action.accountID))
    }

    func threadIDsOf(messageIDs: [String], accountID: String) throws -> Set<String> {
        guard !messageIDs.isEmpty else { return [] }
        return try Set(MessageRecord
            .filter(Column("accountID") == accountID && messageIDs.contains(Column("id")))
            .fetchAll(db)
            .map(\.threadID))
    }
}

/// Pure rules for deriving thread state, kept apart from SQL so they read plainly.
enum ThreadRules {
    static func overlay(_ actions: [PendingAction], onto labels: inout [String: Set<String>], threadID: String) {
        var deleted = Set<String>()
        for action in actions where action.state != .failed && action.state != .undone {
            let targets: [String]
            switch action.kind {
            case .modifyThreads, .trashThreads, .untrashThreads:
                // Gmail applied a sent change to the messages the thread had
                // then, which the diff names; a message that arrived since
                // keeps its own labels. A change still to go out covers
                // whatever the thread holds when it does.
                if !action.threadIDs.contains(threadID) {
                    targets = []
                } else if action.state == .sent {
                    targets = action.diff.keys.filter { labels[$0] != nil }
                } else {
                    targets = Array(labels.keys)
                }
            case .modifyMessages, .trashMessages, .untrashMessages:
                targets = action.messageIDs.filter { labels[$0] != nil }
            case .deleteMessages:
                targets = []
            case .deleteLabel:
                deleted.formUnion(action.labelID.map { [$0] } ?? [])
                targets = []
            case .saveDraft, .sendDraft, .discardDraft, .createLabel, .updateLabel:
                targets = []
            case .createFilter, .deleteFilter, .replaceFilter, .updateVacation, .updateSignature:
                targets = []
            }
            for messageID in targets {
                labels[messageID]?.formUnion(action.addLabelIDs)
                labels[messageID]?.subtract(action.removeLabelIDs)
            }
        }
        // A deleted label leaves every conversation at once, whatever a row
        // queued after the delete would add.
        for messageID in labels.keys {
            labels[messageID]?.subtract(deleted)
        }
    }

    /// Labels a thread is listed under. A message in Trash or Spam lists the
    /// thread only there; every other message contributes its labels and All Mail.
    static func threadLabels(messageLabels: [Set<String>]) -> Set<String> {
        var result = Set<String>()
        for labels in messageLabels {
            if labels.contains(SystemLabel.trash) {
                result.insert(SystemLabel.trash)
            } else if labels.contains(SystemLabel.spam) {
                result.insert(SystemLabel.spam)
            } else {
                result.formUnion(labels)
                result.insert(SystemLabel.allMail)
            }
        }
        return result
    }

    /// Distinct sender display names in order of first appearance.
    static func participants(senders: [String]) -> String {
        var seen = Set<String>()
        return senders
            .map(displayName(fromAddress:))
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ", ")
    }

    /// "Jane Doe <jane@example.com>" gives "Jane Doe"; a bare address is returned as is.
    static func displayName(fromAddress address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "<") else { return trimmed }
        let name = trimmed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        if !name.isEmpty { return name }
        return trimmed[trimmed.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
    }
}
