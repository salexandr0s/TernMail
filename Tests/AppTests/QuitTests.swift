import Foundation
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct QuitTests {
    @Test func anOutboxThatCanNotBeReadNeverPassesForAnEmptyOne() async throws {
        let file = CacheFile()
        let cache = try MailCache.open(at: file.url)
        #expect(try await AppModel.localDrafts(of: ["audit"], in: cache).isEmpty)

        try file.execute("ALTER TABLE localDraft RENAME TO unreadableDraft")
        await #expect(throws: AppModel.QuitProblem.unreadableOutbox) {
            try await AppModel.localDrafts(of: ["audit"], in: cache)
        }
    }

    @Test func choosingQuitAgainWhileAQuitIsUnderWayStartsNothing() async throws {
        let requests = QuitRequests()
        let log = Log()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let first = requests.begin({ log.reviews += 1; for await _ in gate {}; return false }, reply: { log.replies.append($0) })
        let second = requests.begin({ log.reviews += 1; return true }, reply: { log.replies.append($0) })
        #expect(first && !second)
        open.finish()
        try await waitUntil { !requests.isQuitting }
        #expect(log.reviews == 1 && log.replies == [false])

        // Once that quit is answered, the next one starts.
        let third = requests.begin({ log.reviews += 1; return true }, reply: { log.replies.append($0) })
        #expect(third)
        try await waitUntil { !requests.isQuitting }
        #expect(log.reviews == 2 && log.replies == [false, true])
    }

    @MainActor private final class Log {
        var reviews = 0
        var replies: [Bool] = []
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "The quit did not reach the expected state")
    }
}
