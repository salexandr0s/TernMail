import Foundation
import GRDB

/// One message in the thread view.
public struct MessageDetail: Sendable, Equatable, Identifiable {
    public var record: MessageRecord
    /// Server labels with pending actions overlaid.
    public var labels: Set<String>
    public var body: MessageBodyRecord?

    public var id: String { record.id }
    public var isUnread: Bool { labels.contains(SystemLabel.unread) }
    public var isStarred: Bool { labels.contains(SystemLabel.starred) }
}

public struct ThreadDetail: Sendable, Equatable {
    public var thread: ThreadRecord
    public var messages: [MessageDetail]
}

extension MailCache {
    public func labels(accountID: String) -> AsyncThrowingStream<[LabelRecord], any Error> {
        observe { db in
            try LabelRecord
                .filter(Column("accountID") == accountID)
                .order(Column("name").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
        }
    }

    /// Threads listed under `labelID`, newest first.
    public func threads(accountID: String, labelID: String, limit: Int) -> AsyncThrowingStream<[ThreadRecord], any Error> {
        observe { db in
            try ThreadRecord.fetchAll(db, sql: """
                SELECT thread.*
                FROM threadLabel
                JOIN thread ON thread.accountID = threadLabel.accountID AND thread.id = threadLabel.threadID
                WHERE threadLabel.accountID = ? AND threadLabel.labelID = ?
                ORDER BY threadLabel.lastDate DESC, threadLabel.threadID
                LIMIT ?
                """, arguments: [accountID, labelID, limit])
        }
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
            let messages = try transaction.messages(threadID: threadID, accountID: accountID).map {
                MessageDetail(record: $0, labels: labels[$0.id] ?? [], body: bodiesByID[$0.id])
            }
            return ThreadDetail(thread: thread, messages: messages)
        }
    }

    public func syncState(accountID: String) async throws -> SyncStateRecord? {
        try await writer.read { db in try SyncStateRecord.fetchOne(db, key: accountID) }
    }

    private func observe<T: Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> AsyncThrowingStream<T, any Error> {
        let values = ValueObservation.tracking(fetch).values(in: writer)
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
