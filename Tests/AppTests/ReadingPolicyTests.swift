import Foundation
import Testing
@testable import Tern

@Suite @MainActor struct ReadingPolicyTests {
    @Test(.timeLimit(.minutes(1))) func changingConversationCancelsItsDelayedReadAndOnlyTheNewTimerRuns() async throws {
        let controller = DelayedReadController()
        let (events, output) = AsyncStream<Int>.makeStream()
        controller.schedule(delay: .milliseconds(20)) { output.yield(1) }
        controller.cancel()
        controller.schedule(delay: .milliseconds(1)) { output.yield(2) }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == 2)
        controller.cancel()
        try await Task.sleep(for: .milliseconds(30))
        output.finish()
        #expect(await iterator.next() == nil)
    }

    @Test func invalidPreferenceValuesDoNotProduceUnboundedScalingOrDelay() {
        #expect(ReadingPreferences.textScale(.nan) == 1)
        #expect(ReadingPreferences.textScale(10) == 1.5)
        #expect(ReadingPreferences.textScale(0) == 0.85)
        #expect(ReadingPreferences.readDelay(.infinity) == .seconds(3))
        #expect(ReadingPreferences.readDelay(10_000) == .seconds(30))
    }

    @Test func aConversationOpensItsNewestUnreadAndChosenMessages() {
        let ids = ["a", "b", "c", "d"]
        #expect(ReadingPreferences.initiallyExpanded(ids: ids, unread: [], selected: nil) == ["d"])
        #expect(ReadingPreferences.initiallyExpanded(ids: ids, unread: ["b"], selected: nil) == ["b", "d"])
        // A message list opens an older, read message on its own.
        #expect(ReadingPreferences.initiallyExpanded(ids: ids, unread: [], selected: "a") == ["a", "d"])
    }

    @Test func lightBackgroundSendersMatchAnyCaseAndStoreNoAddresses() {
        var senders = LightBackgroundSenders(storage: "")
        senders.set(true, for: "News@Example.com")
        #expect(senders.contains("news@example.com"))
        #expect(!senders.storage.contains("example"))
        let restored = LightBackgroundSenders(storage: senders.storage)
        #expect(restored.contains(" NEWS@example.com "))
        var cleared = restored
        cleared.set(false, for: "news@example.com")
        #expect(cleared.storage.isEmpty)
    }
}
