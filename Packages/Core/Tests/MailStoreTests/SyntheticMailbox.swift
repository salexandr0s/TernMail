import Foundation
import Testing
@testable import MailStore

/// Builds a cache of made-up mail for query-plan tests and benchmarks. The
/// same shape always produces the same rows, so timings compare across runs.
enum SyntheticMailbox {
    struct Shape: Sendable {
        var accounts = 1
        var threads = 1_000
        var messagesPerThread = 2
        var userLabels = 5
        /// Share of threads carrying INBOX; the rest are Sent.
        var inboxShare = 0.6
        var unreadShare = 0.3
        var starredShare = 0.1
        var seed: UInt64 = 7
        /// Newest message date; earlier threads step back from it by `spacing`.
        var newest = Date(timeIntervalSince1970: 1_800_000_000)
        var spacing: TimeInterval = 90
    }

    static let systemLabels = [
        SystemLabel.inbox, SystemLabel.unread, SystemLabel.starred, SystemLabel.important,
        SystemLabel.sent, SystemLabel.draft, SystemLabel.spam, SystemLabel.trash,
    ]

    static func accountID(_ index: Int) -> String { "acct-\(index)" }
    static func threadID(account: Int, thread: Int) -> String { "t\(account)-\(thread)" }
    static func messageID(account: Int, thread: Int, message: Int) -> String { "m\(account)-\(thread)-\(message)" }
    static func userLabelID(_ index: Int) -> String { "Label_\(index)" }

    /// Fills `cache` (a new in-memory one by default) and returns it with the
    /// account IDs it wrote.
    @discardableResult
    static func make(_ shape: Shape = Shape(), into cache: MailCache? = nil) async throws -> (cache: MailCache, accountIDs: [String]) {
        let cache = try cache ?? MailCache.inMemory()
        var random = SplitMix64(seed: shape.seed)
        var accountIDs: [String] = []
        for account in 0..<shape.accounts {
            let accountID = accountID(account)
            accountIDs.append(accountID)
            let labels = systemLabels.map { LabelRecord(accountID: accountID, id: $0, name: $0, isSystem: true) }
                + (0..<shape.userLabels).map {
                    LabelRecord(accountID: accountID, id: userLabelID($0), name: "Project \($0)", isSystem: false)
                }
            try await cache.write { tx in
                try tx.replaceLabels(labels, accountID: accountID)
                try tx.saveCursor(historyID: 1_000, accountID: accountID, fullSyncAt: shape.newest)
            }
            var updates: [CacheTransaction.MessageUpdate] = []
            var threadIDs: [String] = []
            for thread in 0..<shape.threads {
                let threadID = threadID(account: account, thread: thread)
                threadIDs.append(threadID)
                let inInbox = random.next(below: 1) < shape.inboxShare
                let unread = random.next(below: 1) < shape.unreadShare
                let starred = random.next(below: 1) < shape.starredShare
                let userLabel = shape.userLabels > 0 && random.next(below: 1) < 0.4
                    ? userLabelID(Int(random.next(below: Double(shape.userLabels)))) : nil
                let last = shape.newest.addingTimeInterval(-Double(thread) * shape.spacing)
                for message in 0..<shape.messagesPerThread {
                    let date = last.addingTimeInterval(-Double(shape.messagesPerThread - 1 - message) * 3_600)
                    var labelIDs = [inInbox ? SystemLabel.inbox : SystemLabel.sent]
                    if unread, message == shape.messagesPerThread - 1 { labelIDs.append(SystemLabel.unread) }
                    if starred, message == 0 { labelIDs.append(SystemLabel.starred) }
                    if let userLabel { labelIDs.append(userLabel) }
                    let record = MessageRecord(
                        accountID: accountID,
                        id: messageID(account: account, thread: thread, message: message),
                        threadID: threadID,
                        historyID: Int64(100 + thread),
                        date: date,
                        snippet: "Snippet for thread \(thread), message \(message)",
                        sender: "Sender \(thread % 50) <sender\(thread % 50)@example.com>",
                        recipients: "me@example.com",
                        cc: nil,
                        subject: "Subject \(thread)",
                        sizeEstimate: 4_096
                    )
                    updates.append(CacheTransaction.MessageUpdate(record: record, labelIDs: labelIDs))
                }
                if updates.count >= 1_000 || thread == shape.threads - 1 {
                    let batch = updates
                    let threads = threadIDs
                    try await cache.write { tx in
                        try tx.upsertMessages(batch)
                        try tx.rebuildThreads(threads, accountID: accountID)
                    }
                    updates.removeAll(keepingCapacity: true)
                    threadIDs.removeAll(keepingCapacity: true)
                }
            }
        }
        return (cache, accountIDs)
    }

    /// The current rows of a mailbox, for tests that need one value rather than
    /// the observation.
    static func currentThreads(in cache: MailCache, accountIDs: [String], labelID: String, limit: Int = 1_000) async throws -> [ThreadRecord] {
        for try await value in cache.threads(accountIDs: accountIDs, labelID: labelID, limit: limit) {
            return value
        }
        return []
    }
}

/// Deterministic generator so the fixture is the same every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<upper`.
    mutating func next(below upper: Double) -> Double {
        Double(next() >> 11) / Double(1 << 53) * upper
    }
}

@Suite struct SyntheticMailboxTests {
    @Test func fillsInboxDeterministically() async throws {
        let shape = SyntheticMailbox.Shape(threads: 200, userLabels: 3)
        let first = try await SyntheticMailbox.make(shape)
        let second = try await SyntheticMailbox.make(shape)
        let inbox = try await SyntheticMailbox.currentThreads(in: first.cache, accountIDs: first.accountIDs, labelID: SystemLabel.inbox)
        let inboxAgain = try await SyntheticMailbox.currentThreads(in: second.cache, accountIDs: second.accountIDs, labelID: SystemLabel.inbox)
        #expect(first.accountIDs == ["acct-0"])
        #expect(inbox.count > 80 && inbox.count < 160)
        #expect(inbox.map(\.id) == inboxAgain.map(\.id))
        #expect(inbox.contains { $0.isUnread } && inbox.contains { !$0.isUnread })
        #expect(zip(inbox, inbox.dropFirst()).allSatisfy { $0.lastDate >= $1.lastDate })
    }
}
