import Foundation
import GmailAPI
import MailStore
import MessageContent
import ImageIO
import SyncEngine
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct PerformanceAuditTransportTests {
    @Test func cancellationAndConditionChangesCannotCompleteObsoleteRequests() async throws {
        let transport = PerformanceAuditTransport(bodyDelay: .seconds(10))
        await transport.configure(.delayed)
        let request = Task { try await transport.request(.body) }
        try await waitUntil { await transport.statistics().requestCounts["body"] == 1 }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await transport.statistics().cancelledRequests == 1)

        let obsolete = Task { try await transport.request(.body) }
        try await waitUntil { await transport.statistics().requestCounts["body"] == 2 }
        await transport.configure(.offline)
        obsolete.cancel()
        await #expect(throws: CancellationError.self) { try await obsolete.value }
        #expect(await transport.statistics().cancelledRequests == 0)
        #expect(await transport.statistics().completedRequests == 0)
        await #expect(throws: URLError.self) { try await transport.request(.metadata) }
        #expect(await transport.statistics().offlineFailures == 1)
    }

    @Test func optionalResourceDoesNotWaitForDelayedRequiredBody() async throws {
        let transport = PerformanceAuditTransport(bodyDelay: .seconds(10))
        await transport.configure(.delayed)
        let body = Task { try await transport.request(.body) }
        try await waitUntil { await transport.statistics().requestCounts["body"] == 1 }
        _ = try await transport.request(.optionalResource)
        #expect(await transport.statistics().completedRequests == 1)
        body.cancel()
        await #expect(throws: CancellationError.self) { try await body.value }
    }

    @Test func deliveryHandlesRegistrationRaceAndIsolatesAccountAndGeneration() async throws {
        var deliveries: [UInt64] = []
        let transport = PerformanceAuditTransport { generation, _ in deliveries.append(generation) }
        let first = await transport.willSelect(accountID: "first", threadID: "same")
        await transport.bodyDelivered(accountID: "second", threadID: "same", at: .now)
        await transport.didSelect(first, generation: 1)
        await transport.waitForNotification()
        #expect(deliveries.isEmpty)
        await transport.bodyDelivered(accountID: "first", threadID: "same", at: .now)
        await transport.bodyDelivered(accountID: "first", threadID: "same", at: .now)
        await transport.waitForNotification()
        #expect(deliveries == [1])

        let second = await transport.willSelect(accountID: "second", threadID: "next")
        await transport.bodyDelivered(accountID: "second", threadID: "next", at: .now)
        await transport.didSelect(first, generation: 99)
        await transport.didSelect(second, generation: 2)
        await transport.waitForNotification()
        #expect(deliveries == [1, 2])
        #expect(await transport.statistics().selectedBodyDeliveries == 2)
    }

    @Test func actualSyncEngineKeepsOfflineCacheAndPublishesActiveHistoryChanges() async throws {
        let transport = PerformanceAuditTransport(bodyDelay: .milliseconds(10))
        let gmail = AuditGmail(performanceTransport: transport)
        let cache = try MailCache.inMemory()
        let engine = makeEngine(cache: cache, gmail: gmail)
        try await engine.sync()
        let original = try await detail(in: cache)
        #expect(original?.messages.first?.isStarred == false)
        await transport.configure(.activeSync)
        try await engine.sync()
        let changed = try await detail(in: cache)
        #expect(changed?.messages.first?.isStarred == true)
        #expect(await transport.statistics().requestCounts["history", default: 0] > 0)

        await transport.configure(.offline)
        await #expect(throws: (any Error).self) { try await engine.sync() }
        let offline = try await detail(in: cache)
        #expect(offline == changed)
        #expect(await transport.statistics().offlineFailures > 0)
        await engine.stop()
    }

    @Test func performanceMetadataHasNoBodyAndInlineImageCorpusUsesValidResources() async throws {
        let transport = PerformanceAuditTransport(bodyDelay: .milliseconds(5))
        let gmail = AuditGmail(performanceTransport: transport, performanceFixtureCount: 200)
        let cache = try MailCache.inMemory()
        let engine = makeEngine(cache: cache, gmail: gmail)
        try await engine.sync()
        let missing = try await cache.read { try $0.messageIDsWithoutBody(threadID: "performance-network-0", accountID: "ui-audit") }
        #expect(missing == ["performance-network-0"])
        await transport.configure(.delayed)
        try await engine.openThread("performance-network-0", markRead: false)
        #expect(try await cache.read { try $0.body(messageID: "performance-network-0", accountID: "ui-audit") } != nil)
        #expect(await transport.statistics().requestCounts["body", default: 0] > 0)
        await transport.configure(.idle)
        try await engine.openThread("performance-thread-2", markRead: false)
        let resources = try await cache.read { try $0.mimeResources(messageID: "performance-2", accountID: "ui-audit") }
        #expect(resources.count == 8)
        #expect(resources.allSatisfy { $0.data.starts(with: [137, 80, 78, 71]) })
        try await engine.openThread("performance-image-heavy-0", markRead: false)
        let large = try await cache.read { try $0.mimeResources(messageID: "performance-image-heavy-0", accountID: "ui-audit") }
        #expect(large.count == 8)
        let resource = try #require(large.first)
        let source = try #require(CGImageSourceCreateWithData(resource.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 512 && image.height == 384)
        #expect(AuditGmail.performanceImageCorpora.last?.decodedPixelBytesPerMessage == 6 * 1_024 * 1_024)
        await engine.stop()
    }

    @Test func networkCorpusSearchKeepsTargetsInTheSnapshotAndOutsideNearbyPrefetch() async throws {
        let transport = PerformanceAuditTransport()
        let gmail = AuditGmail(performanceTransport: transport, performanceFixtureCount: 200)
        let cache = try MailCache.inMemory()
        let mailbox = MailboxModel(account: AccountRecord(id: "ui-audit", email: "audit@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now), cache: cache, gmail: gmail, outgoingDirectory: FileManager.default.temporaryDirectory)
        await mailbox.start()
        do {
            try await waitUntil { mailbox.hasSyncedOnce }
            mailbox.search.update("Synthetic network body")
            mailbox.search.submit()
            try await waitUntil { mailbox.search.hasLocalAnswer && mailbox.listItems.count >= 200 }
            mailbox.search.loadMoreResults()
            try await waitUntil { mailbox.listItems.count >= 400 }
            mailbox.search.loadMoreResults()
            try await waitUntil { mailbox.listItems.count == 600 }
            let keys = Set((0..<100).map { ThreadKey(accountID: "ui-audit", threadID: "performance-network-\(20 + $0 * 5)") })
            let rows = mailbox.listItems.map(\.id)
            #expect(keys.isSubset(of: Set(rows.map(\.threadKey))))
            for key in keys {
                let row = try #require(rows.first { $0.threadKey == key })
                let neighbours = Set(MessagePrefetchPlan.candidates(rows: rows, selected: [row]))
                #expect(neighbours.isDisjoint(with: keys))
            }
            let selected = try #require(rows.first { $0.threadID == "performance-network-20" })
            mailbox.selectListRows([selected])
            await transport.configure(.activeSync)
            try await mailbox.accounts[0].engine.sync()
            #expect(mailbox.selectedListRowIDs == [selected])
            #expect(mailbox.listItems.contains { $0.id == selected })
            await mailbox.stop()
        } catch {
            await mailbox.stop()
            throw error
        }
    }

    @Test func calendarReadsHonorOfflineTransportWithoutChangingCachedServiceEvents() async throws {
        let transport = PerformanceAuditTransport()
        let calendar = CalendarAuditService(now: .now, performanceTransport: transport)
        let original = try await calendar.events(calendarID: "work", query: CalendarEventQuery())
        await transport.configure(.offline)
        await #expect(throws: URLError.self) { try await calendar.events(calendarID: "work", query: CalendarEventQuery()) }
        await transport.configure(.idle)
        let returned = try await calendar.events(calendarID: "work", query: CalendarEventQuery())
        #expect(Set(original.items.map(\.id)) == Set(returned.items.map(\.id)))
    }

    private func detail(in cache: MailCache) async throws -> ThreadDetail? {
        for try await value in cache.thread(accountID: "ui-audit", threadID: "t1") { return value }
        return nil
    }

    private func makeEngine(cache: MailCache, gmail: AuditGmail) -> SyncEngine {
        SyncEngine(accountID: "ui-audit", sender: EmailAddress(address: "audit@example.invalid"),
                   outgoingDirectory: FileManager.default.temporaryDirectory, gmail: gmail, cache: cache,
                   sendsAutomatically: false, indexesAttachmentsAutomatically: false)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }
}
