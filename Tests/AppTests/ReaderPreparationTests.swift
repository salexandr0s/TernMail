import Foundation
import MailStore
import MessageContent
import Observation
import Synchronization
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

    @Test func retainedActivationDoesNotRepublishPresentation() {
        let owner = NSObject(), store = ReaderSessionStore()
        let ids = (0..<3).map {
            ReaderSessionID(key: ThreadKey(accountID: "a", threadID: "t\($0)"), messageID: nil, owner: ObjectIdentifier(owner))
        }
        for id in ids { store.activate(id) }
        store.setVisible(true, selected: ids[2])
        let changes = Mutex(0)
        let before = withObservationTracking {
            presentation(of: store, selecting: ids[0])
        } onChange: { changes.withLock { $0 += 1 } }
        #expect(store.sessions == ids, "Projecting the next selection must not mutate recency")

        store.activate(ids[0])
        let after = presentation(of: store, selecting: ids[0])
        #expect(before.display == after.display, "Retained selection keeps the displayed session identities")
        #expect(before.sources == after.sources, "Retained selection keeps the source snapshots")
        #expect(after.hidden == [ids[2], ids[0]], "Hidden renderers follow MRU order, not display order")
        #expect(before == after, "The first presentation must already predict the selected session's hidden-window retention")
        #expect(changes.withLock { $0 } == 0, "Warm activation must not request a corrective presentation pass")
        #expect(store.sessions == [ids[1], ids[2], ids[0]])
    }

    @Test func noOpSourceRetentionDoesNotNotifyObservers() {
        let owner = NSObject(), store = ReaderSessionStore()
        let id = ReaderSessionID(key: ThreadKey(accountID: "a", threadID: "retained"), messageID: nil, owner: ObjectIdentifier(owner))
        store.activate(id)
        store.setVisible(true, selected: id)
        let operations: [(String, @MainActor () -> Void)] = [
            ("activate retained source", { store.activate(id) }),
            ("show retained source", { store.setVisible(true, selected: id) }),
            ("release absent hidden sources", { store.releaseHidden(keeping: id) })
        ]
        for (name, operation) in operations {
            let changes = Mutex(0)
            let before = withObservationTracking { store.retainsSource(for: id) } onChange: {
                changes.withLock { $0 += 1 }
            }
            operation()
            #expect(before && store.retainsSource(for: id))
            #expect(changes.withLock { $0 } == 0, "\(name) must not publish an unchanged source-retention set")
        }
    }

    @Test func presentationMembershipChangesNotifyObservers() {
        let owner = NSObject(), store = ReaderSessionStore()
        let ids = (0..<4).map {
            ReaderSessionID(key: ThreadKey(accountID: "a", threadID: "t\($0)"), messageID: nil, owner: ObjectIdentifier(owner))
        }
        for id in ids.prefix(3) { store.activate(id) }
        let additions = Mutex(0)
        let before = withObservationTracking { presentation(of: store, selecting: ids[2]) } onChange: {
            additions.withLock { $0 += 1 }
        }
        store.activate(ids[3])
        let after = presentation(of: store, selecting: ids[3])
        #expect(additions.withLock { $0 } == 1, "Actual membership changes must invalidate presentation")
        #expect(before.display != after.display)
        #expect(store.sessions == [ids[1], ids[2], ids[3]])
        #expect(after.display == Array(ids.suffix(3)))

        let removals = Mutex(0)
        _ = withObservationTracking { presentation(of: store, selecting: ids[3]) } onChange: {
            removals.withLock { $0 += 1 }
        }
        store.releaseHidden(keeping: ids[3])
        #expect(removals.withLock { $0 } == 1, "Releasing hidden sessions must invalidate presentation")
        #expect(presentation(of: store, selecting: ids[3]).display == [ids[3]])
    }

    @Test func sourceEvictionAndRestorationNotifyAcrossSessionStores() async throws {
        let detail = try await sourceSnapshot()
        let owner = NSObject(), otherOwner = NSObject()
        let id = ReaderSessionID(key: detail.thread.key, messageID: nil, owner: ObjectIdentifier(owner))
        let otherID = ReaderSessionID(key: detail.thread.key, messageID: nil, owner: ObjectIdentifier(otherOwner))
        let store = ReaderSessionStore(), other = ReaderSessionStore()
        store.setVisible(true, selected: id); store.activate(id); store.record(detail, for: id, selected: id)
        other.setVisible(true, selected: otherID); other.activate(otherID); other.record(detail, for: otherID, selected: otherID)
        store.setVisible(false, selected: id)
        #expect(store.retainsSource(for: id), "One six-MiB hidden snapshot fits the shared budget")
        let evictions = Mutex(0)
        _ = withObservationTracking { store.retainsSource(for: id) } onChange: {
            evictions.withLock { $0 += 1 }
        }
        other.setVisible(false, selected: otherID)
        #expect(!store.retainsSource(for: id), "Another store's hidden source must evict the older snapshot")
        #expect(other.retainsSource(for: otherID))
        #expect(evictions.withLock { $0 } == 1)
        #expect(store.sessions == [id], "Source eviction keeps its lightweight session identity")

        let restorations = Mutex(0)
        _ = withObservationTracking { store.retainsSource(for: id) } onChange: {
            restorations.withLock { $0 += 1 }
        }
        store.setVisible(true, selected: id)
        #expect(store.retainsSource(for: id), "The selected visible source is protected")
        #expect(restorations.withLock { $0 } == 1)
        #expect(other.retainsSource(for: otherID))
        store.setVisible(false, selected: id)
        #expect(!store.retainsSource(for: id), "Restoration must preserve the source's cost for later pressure")
    }

    private struct SessionPresentation: Equatable {
        let display: [ReaderSessionID]
        let hidden: [ReaderSessionID]
        let sources: [Bool]
    }

    private func presentation(of store: ReaderSessionStore, selecting selected: ReaderSessionID) -> SessionPresentation {
        let recent = store.presenting(selected)
        let display = recent.sorted { $0.precedesInPresentation($1) }
        return SessionPresentation(display: display, hidden: Array(recent.suffix(2)),
            sources: display.map { store.retainsSource(for: $0) })
    }

    private func sourceSnapshot() async throws -> ThreadDetail {
        let cache = try MailCache.inMemory()
        let text = String(repeating: "x", count: 2 * 1_024 * 1_024)
        try await cache.write { tx in
            let message = MessageRecord(accountID: "a", id: "source", threadID: "source", historyID: 1,
                date: .distantPast, snippet: "", sender: "reader@example.invalid", recipients: "audit@example.invalid",
                cc: nil, subject: "Synthetic source", sizeEstimate: text.utf8.count)
            try tx.upsertMessages([.init(record: message, labelIDs: [SystemLabel.inbox])])
            try tx.saveBodies([.init(accountID: "a", messageID: "source", html: nil, plainText: text, fetchedAt: .distantPast)])
            try tx.rebuildThreads(["source"], accountID: "a")
        }
        var iterator = cache.thread(accountID: "a", threadID: "source").makeAsyncIterator()
        let snapshot = try await iterator.next()
        return try #require(snapshot ?? nil)
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
