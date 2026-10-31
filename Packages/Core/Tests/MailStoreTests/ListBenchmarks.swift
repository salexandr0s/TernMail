import Foundation
import GRDB
import Testing
@testable import MailStore

/// Timings for the list over a large mailbox. Off by default; run with
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
