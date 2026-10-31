import Foundation
import GRDB
import MessageContent

/// One message list as a single read saw it: the conversations in list order
/// and the messages they show. Read together, the two always agree, where
/// two chained observations could pair one write's conversations with
/// another's messages.
public struct MailListPage: Sendable, Equatable {
    public let threads: [ThreadRecord]
    public let entries: [MessageListEntry]
    /// A hash of `threads` and `entries`. Equal pages have equal fingerprints
    /// for the life of the process, so a consumer can tell that a page
    /// changed without comparing the arrays.
    public let fingerprint: Int

    public static let empty = MailListPage(threads: [], entries: [])

    public init(threads: [ThreadRecord], entries: [MessageListEntry]) {
        self.threads = threads
        self.entries = entries
        var hasher = Hasher()
        hasher.combine(threads)
        hasher.combine(entries)
        fingerprint = hasher.finalize()
    }

    public static func == (lhs: MailListPage, rhs: MailListPage) -> Bool {
        lhs.fingerprint == rhs.fingerprint && lhs.threads == rhs.threads && lhs.entries == rhs.entries
    }
}

/// What a message list shows, read as a `MailListPage`. A mailbox takes
/// its conversations from `threadLabel`. Search results and the snoozed list
/// name theirs and keep their order, and the page reads each named
/// conversation again, so its row and its messages come from one read.
public struct MailListPageBuilder: Sendable {
    enum Conversations: Sendable {
        case mailbox(accountIDs: [String], labelID: String, limit: Int)
        case listed([ThreadRecord])
    }

    let conversations: Conversations
    let query: SearchQuery?
    let includingMessageIDs: [String: Set<String>]
    let snoozedOnly: Bool

    /// The newest `limit` conversations under `labelID` across the accounts,
    /// a snoozed conversation that came back counting from its wake time.
    public static func mailbox(accountIDs: [String], labelID: String, limit: Int) -> MailListPageBuilder {
        MailListPageBuilder(
            conversations: .mailbox(accountIDs: accountIDs, labelID: labelID, limit: limit),
            query: nil, includingMessageIDs: [:], snoozedOnly: false
        )
    }

    /// Search results in the order given. With a query that runs locally, a
    /// conversation shows the messages it matches here and those
    /// `includingMessageIDs` names for their account, which Gmail matched.
    public static func searchResults(
        _ threads: [ThreadRecord], matching query: SearchQuery?, includingMessageIDs: [String: Set<String>] = [:]
    ) -> MailListPageBuilder {
        MailListPageBuilder(
            conversations: .listed(threads), query: query, includingMessageIDs: includingMessageIDs, snoozedOnly: false
        )
    }

    /// Snoozed conversations in the order given, each showing its snoozed
    /// messages, or all of them when the whole conversation is snoozed.
    public static func snoozed(_ threads: [ThreadRecord]) -> MailListPageBuilder {
        MailListPageBuilder(conversations: .listed(threads), query: nil, includingMessageIDs: [:], snoozedOnly: true)
    }

    /// Reads the page in one transaction.
    public func page(in tx: CacheTransaction) throws -> MailListPage {
        let threads: [ThreadRecord]
        switch conversations {
        case .mailbox(let accountIDs, let labelID, let limit):
            guard !accountIDs.isEmpty else { return .empty }
            threads = try ThreadRecord.fetchAll(
                tx.db, sql: ThreadListQuery.sql(accountCount: accountIDs.count),
                arguments: ThreadListQuery.arguments(accountIDs: accountIDs, labelID: labelID, limit: limit)
            )
        case .listed(let listed):
            threads = try Self.stored(listed, in: tx)
        }
        guard !threads.isEmpty else { return .empty }
        let threadsByAccount = Dictionary(grouping: threads, by: \.accountID).mapValues { $0.map(\.id) }
        let entries = try tx.messageListEntries(
            threadsByAccount: threadsByAccount, matching: query,
            includingMessageIDs: includingMessageIDs, snoozedOnly: snoozedOnly
        )
        return MailListPage(threads: threads, entries: entries)
    }

    /// The listed conversations as the cache holds them now, in the order
    /// given. One the cache no longer holds is left out.
    static func stored(_ listed: [ThreadRecord], in tx: CacheTransaction) throws -> [ThreadRecord] {
        var current: [String: [String: ThreadRecord]] = [:]
        for (accountID, threads) in Dictionary(grouping: listed, by: \.accountID) {
            let ids = Set(threads.map(\.id)).sorted()
            var arguments: StatementArguments = [accountID]
            arguments += StatementArguments(ids)
            let rows = try ThreadRecord.fetchAll(
                tx.db, sql: "SELECT * FROM thread WHERE accountID = ? AND id IN (\(databaseQuestionMarks(count: ids.count)))",
                arguments: arguments
            )
            current[accountID] = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        }
        return listed.compactMap { current[$0.accountID]?[$0.id] }
    }
}
