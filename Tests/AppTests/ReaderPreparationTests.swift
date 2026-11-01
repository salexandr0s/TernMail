import Foundation
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct ReaderPreparationTests {
    @Test func recentlyPreparedDocumentsReuseTheirImmutableResourceCapabilities() async throws {
        let cache = ReaderPreparedCache(byteLimit: 100_000)
        let owner = NSObject()
        let firstBody = body("a"), secondBody = body("b")
        let firstKey = key(firstBody, owner: owner), secondKey = key(secondBody, owner: owner)
        let resource = MIMEInlineResourceRecord(accountID: "account", messageID: "a", contentID: "logo", partID: "1", mimeType: "image/png", data: Data([1, 2, 3]))
        let first = try await cache.prepare(key: firstKey, body: firstBody, resources: [resource])
        _ = try await cache.prepare(key: secondKey, body: secondBody, resources: [])
        let returned = try await cache.prepare(key: firstKey, body: firstBody, resources: [resource])
        #expect(cache.preparationCount == 2)
        #expect(first.resources.scope == returned.resources.scope)
        #expect(first.rendered?.html == returned.rendered?.html)
        #expect(cache.byteCount <= cache.byteLimit)
        cache.invalidate(accountID: "account", messageID: "a")
        #expect(cache.value(for: firstKey) == nil)
        #expect(cache.value(for: secondKey) != nil)
    }

    @Test(.timeLimit(.minutes(1))) func selectedPreparationBypassesAHeldSpeculativeLane() async throws {
        let lane = ReaderPreparationLane()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holding = Task.detached { await lane.holdForTest(entered: entered, release: release) }
        defer { release.signal() }
        try await waitUntil { entered.wait(timeout: .now()) == .success }
        let cache = ReaderPreparedCache(speculative: lane)
        let owner = NSObject(), source = body("a")
        let identity = key(source, owner: owner)
        let speculative = Task { try await cache.prepare(key: identity, body: source, resources: [], isSpeculative: true) }
        try await waitUntil { cache.waiterCount(for: identity) == 1 }
        let selected = Task { try await cache.prepare(key: identity, body: source, resources: []) }
        // Foreground finishes while the speculative actor is still held.
        let document = try await selected.value
        #expect(document.searchableText.contains("Message a"))
        speculative.cancel()
        release.signal()
        await holding.value
        await #expect(throws: CancellationError.self) { try await speculative.value }
        #expect(cache.value(for: identity)?.resources.scope == document.resources.scope)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingOneJoinedConsumerDoesNotCancelTheSelectedConsumer() async throws {
        let lane = ReaderPreparationLane()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holding = Task.detached { await lane.holdForTest(entered: entered, release: release) }
        defer { release.signal() }
        try await waitUntil { entered.wait(timeout: .now()) == .success }
        let cache = ReaderPreparedCache(foreground: lane)
        let owner = NSObject(), source = body("a")
        let identity = key(source, owner: owner)
        let first = Task { try await cache.prepare(key: identity, body: source, resources: []) }
        try await waitUntil { cache.waiterCount(for: identity) == 1 }
        let selected = Task { try await cache.prepare(key: identity, body: source, resources: []) }
        try await waitUntil { cache.waiterCount(for: identity) == 2 }
        first.cancel()
        try await waitUntil { cache.waiterCount(for: identity) == 1 }
        release.signal(); await holding.value
        let document = try await selected.value
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(document.searchableText.contains("Message a"))
        #expect(cache.preparationCount == 1)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func invalidationRevokesEveryJoinedConsumer(accountWide: Bool) async throws {
        let lane = ReaderPreparationLane()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holding = Task.detached { await lane.holdForTest(entered: entered, release: release) }
        defer { release.signal() }
        try await waitUntil { entered.wait(timeout: .now()) == .success }
        let cache = ReaderPreparedCache(foreground: lane)
        let owner = NSObject(), source = body("a")
        let identity = key(source, owner: owner)
        let first = Task { try await cache.prepare(key: identity, body: source, resources: []) }
        let second = Task { try await cache.prepare(key: identity, body: source, resources: []) }
        try await waitUntil { cache.waiterCount(for: identity) == 2 }
        cache.invalidate(accountID: "account", messageID: accountWide ? nil : "a")
        release.signal(); await holding.value
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(cache.value(for: identity) == nil)
        let retried = try await cache.prepare(key: identity, body: source, resources: [])
        #expect(retried.searchableText.contains("Message a"))
    }

    @Test func sessionsRetainThreeRecentIdentitiesAndReuseTheReturningSession() {
        let owner = NSObject(), store = ReaderSessionStore()
        let ids = (0..<4).map { ReaderSessionID(key: ThreadKey(accountID: "a", threadID: "t\($0)"), messageID: nil, owner: ObjectIdentifier(owner)) }
        for id in ids.prefix(3) { store.activate(id) }
        let originalDisplay = store.presenting(ids[2]).sorted { $0.precedesInPresentation($1) }
        #expect(originalDisplay == Array(ids.prefix(3)))

        store.activate(ids[0])
        #expect(store.sessions == [ids[1], ids[2], ids[0]])
        #expect(store.presenting(ids[0]).sorted { $0.precedesInPresentation($1) } == originalDisplay)

        // The provisional presentation must retain the next selected session
        // without changing recency until activation. B remains the eviction.
        let pending = store.presenting(ids[3])
        #expect(pending == [ids[2], ids[0], ids[3]])
        #expect(store.sessions == [ids[1], ids[2], ids[0]])
        store.activate(ids[3])
        let recent = store.presenting(ids[3])
        let display = recent.sorted { $0.precedesInPresentation($1) }
        #expect(recent == pending)
        #expect(store.sessions == [ids[2], ids[0], ids[3]])
        #expect(display == [ids[0], ids[2], ids[3]])
        // Whole-window inactivity keeps the most recent two renderers. Using
        // the display suffix instead would incorrectly retain C rather than A.
        #expect(Array(recent.suffix(2)) == [ids[0], ids[3]])
        #expect(Array(display.suffix(2)) == [ids[2], ids[3]])
        store.releaseHidden(keeping: ids[3])
        #expect(store.sessions == [ids[3]])
    }

    @Test func presentationOrderPreservesDistinctMessagesAndAccountOwners() {
        let owner = NSObject(), replacement = NSObject()
        let key = ThreadKey(accountID: "a", threadID: "a")
        let conversation = ReaderSessionID(key: key, messageID: nil, owner: ObjectIdentifier(owner))
        let replacedConversation = ReaderSessionID(key: key, messageID: nil, owner: ObjectIdentifier(replacement))
        let emptyMessage = ReaderSessionID(key: key, messageID: "", owner: ObjectIdentifier(owner))
        let message = ReaderSessionID(key: key, messageID: "message", owner: ObjectIdentifier(owner))
        let otherThread = ReaderSessionID(key: ThreadKey(accountID: "a", threadID: "b"), messageID: nil, owner: ObjectIdentifier(owner))
        let otherAccount = ReaderSessionID(key: ThreadKey(accountID: "b", threadID: "a"), messageID: nil, owner: ObjectIdentifier(owner))
        let identities = [message, otherAccount, replacedConversation, otherThread, emptyMessage, conversation]
        let display = identities.sorted { $0.precedesInPresentation($1) }
        #expect(Set(display).count == identities.count)
        #expect(Set(display.prefix(2)) == [conversation, replacedConversation])
        #expect(display[0].owner < display[1].owner)
        #expect(Array(display.dropFirst(2)) == [emptyMessage, message, otherThread, otherAccount])
        #expect(identities.reversed().sorted { $0.precedesInPresentation($1) } == display)
        for (index, id) in display.enumerated() {
            #expect(!id.precedesInPresentation(id))
            for later in display.dropFirst(index + 1) {
                #expect(id.precedesInPresentation(later))
                #expect(!later.precedesInPresentation(id))
            }
        }
    }

    @Test func everyFindRequestCanRematerializeTheSameOffscreenMessage() async throws {
        let finder = ReaderFindModel()
        finder.order = ["a"]; finder.query = "needle"; finder.show()
        finder.setSearchableText("needle", for: "a")
        finder.find(forward: true)
        try await waitUntil { finder.requestRevision > 0 }
        let revision = finder.requestRevision
        #expect(finder.requestedMessageID == "a")
        finder.find(forward: true)
        try await waitUntil { finder.requestRevision > revision }
        #expect(finder.requestedMessageID == "a")
        finder.hide()
    }

    private func body(_ id: String) -> MessageBodyRecord {
        .init(accountID: "account", messageID: id, html: "<p>Message \(id)</p><img src='cid:logo'>", plainText: nil, fetchedAt: .distantPast)
    }
    private func key(_ body: MessageBodyRecord, owner: NSObject) -> ReaderPreparationKey {
        .init(accountID: body.accountID, owner: ObjectIdentifier(owner), messageID: body.messageID, body: ReaderBodyVersion(body), resourcesRevision: 1, allowsImages: false, textOnly: false, textScale: 1)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Reader work did not reach its expected state")
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private extension ReaderPreparationLane {
    // Holds only this actor's worker, never the main actor, making queue and
    // cancellation races deterministic without production-only test hooks.
    func holdForTest(entered: DispatchSemaphore, release: DispatchSemaphore) {
        entered.signal()
        release.wait()
    }
}
