import Foundation
import MailStore
import MessageContent
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
        #expect(ReadingPreferences.textScale(10) == 2)
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

    /// Remote images load for a remembered sender only once the saved list
    /// has been read, only for a verified sender, and only while it is listed.
    @Test func rememberedImageSendersGrantOnlyWhatTheSavedListHolds() async throws {
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "account", email: "me@example.com", displayName: nil,
            grantedScopes: [], addedAt: .now))
        try await store.setImageSenderAllowed(true, address: "News@Example.com", accountID: "account")
        let verified = SenderImageIdentity(accountID: "account", messageID: "first",
            from: "News <news@example.com>", verifiedSender: "news@example.com")
        let unverified = SenderImageIdentity(accountID: "account", messageID: "second",
            from: "News <news@example.com>", verifiedSender: nil)

        let senders = ImageSenderAllowSet(accountID: "account")
        #expect(!senders.isKnown)
        #expect(senders.remembered(verified) == nil)
        senders.record(true, address: "news@example.com")
        #expect(senders.remembered(verified) == nil)

        await senders.load(from: store)
        #expect(senders.isKnown)
        #expect(senders.remembered(verified) == verified)
        #expect(senders.remembered(unverified) == nil)
        let otherAccount = SenderImageIdentity(accountID: "other", messageID: "first",
            from: "News <news@example.com>", verifiedSender: "news@example.com")
        #expect(senders.remembered(otherAccount) == nil)
        senders.record(false, address: "NEWS@example.com")
        #expect(senders.remembered(verified) == nil)

        let withoutStore = ImageSenderAllowSet(accountID: "account")
        await withoutStore.load(from: nil)
        #expect(withoutStore.isKnown)
        #expect(withoutStore.remembered(verified) == nil)
    }
}
