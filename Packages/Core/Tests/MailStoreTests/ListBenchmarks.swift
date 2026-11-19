import Foundation
import GRDB
import MessageContent
import Testing
@testable import MailStore

/// Timings for the list and local search over a large mailbox, and for
/// sync's writes. Off by default; run with
/// `TERN_BENCHMARKS=1 swift test --package-path Packages/Core --filter ListBenchmarks`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERN_BENCHMARKS"] == "1"), .serialized)
struct ListBenchmarks {
    @Test func anInboxPageOverThreeLargeAccounts() async throws {
        let (cache, accountIDs) = try await SyntheticMailbox.make(.init(accounts: 3, threads: 20_000))
        let sql = ThreadListQuery.sql(accountCount: accountIDs.count)
        let arguments = ThreadListQuery.arguments(accountIDs: accountIDs, labelID: SystemLabel.inbox, limit: 200)
        let query = try await median(runs: 20) {
            _ = try await cache.read { tx in try ThreadRecord.fetchAll(tx.db, sql: sql, arguments: arguments) }
        }
        let firstValue = try await median(runs: 10) {
            _ = try await SyntheticMailbox.currentThreads(in: cache, accountIDs: accountIDs, labelID: SystemLabel.inbox, limit: 200)
        }
        let rebuild = try await median(runs: 20) {
            try await cache.write { tx in
                try tx.rebuildThreads([SyntheticMailbox.threadID(account: 0, thread: 10)], accountID: accountIDs[0])
            }
        }
        print("list page: query \(ms(query)) ms, first observation value \(ms(firstValue)) ms, one rebuild \(ms(rebuild)) ms")
        #expect(query < .milliseconds(10))
        #expect(firstValue < .milliseconds(30))
        #expect(rebuild < .milliseconds(10))
    }

    /// Searches that check every message of an account: text that every
    /// message has, a label alone, and both. Local search runs again on
    /// each typed key.
    @Test func searchesOverThreeLargeAccounts() async throws {
        let (cache, accountIDs) = try await SyntheticMailbox.make(.init(accounts: 3, threads: 20_000))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func search(_ text: String) async throws -> Duration {
            let query = SearchQuery(text)
            return try await median(runs: 9) {
                for accountID in accountIDs {
                    _ = try await cache.read { tx in
                        try tx.searchThreads(query, accountID: accountID, timeZone: .gmt, now: now, limit: 200)
                    }
                }
            }
        }
        let text = try await search("subject")
        let label = try await search("is:unread")
        let both = try await search("label:project-1 subject")
        print("search: text \(ms(text)) ms, label \(ms(label)) ms, both \(ms(both)) ms")
        #expect(text < .milliseconds(130))
        #expect(label < .milliseconds(60))
        #expect(both < .milliseconds(140))
    }

    /// Sync's writes for 5,000 new messages and their conversations, then
    /// for the same messages again with nothing new, as the last pass of a
    /// full sync stores them. Every other write waits for these, the user's
    /// own actions included.
    @Test func storingFiveThousandMessages() async throws {
        let shape = SyntheticMailbox.Shape(threads: 2_500)
        let clock = ContinuousClock()
        var new: [Duration] = []
        var unchanged: [Duration] = []
        for _ in 0..<3 {
            let cache = try MailCache.inMemory()
            new.append(try await clock.measure { _ = try await SyntheticMailbox.make(shape, into: cache) })
            unchanged.append(try await clock.measure { _ = try await SyntheticMailbox.make(shape, into: cache) })
        }
        let newMedian = new.sorted()[1]
        let unchangedMedian = unchanged.sorted()[1]
        print("storing 5,000 messages: new \(ms(newMedian)) ms, unchanged \(ms(unchangedMedian)) ms")
        #expect(newMedian < .milliseconds(2_000))
        #expect(unchangedMedian < .milliseconds(1_250))
    }
}

private func median(runs: Int, _ body: () async throws -> Void) async throws -> Duration {
    let clock = ContinuousClock()
    var samples: [Duration] = []
    for _ in 0..<runs {
        samples.append(try await clock.measure(body))
    }
    return samples.sorted()[runs / 2]
}

private func ms(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return String(format: "%.2f", Double(seconds) * 1_000 + Double(attoseconds) / 1e15)
}
