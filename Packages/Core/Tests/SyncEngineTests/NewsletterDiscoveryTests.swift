import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct NewsletterDiscoveryTests {
    @Test func pagesResumeAcrossEnginesAndDeduplicateNewsletterCounts() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try newsletterMessage("first"))
        await gmail.setRecentPages([try newsletterPage(["first"], next: "older")])
        let first = try await engine.loadNewsletterPage()
        #expect(first.scannedMessageCount == 1)
        #expect(first.subscriptions.first?.messageCount == 1)
        #expect(!first.isComplete)
        await engine.stop()
        let (resumed, _, nextGmail, _) = try await makeEngine(cache: cache)
        await nextGmail.add(try newsletterMessage("first"))
        await nextGmail.add(try newsletterMessage("second"))
        await nextGmail.setRecentPages([try newsletterPage(["first", "second"], next: nil)])
        let complete = try await resumed.loadNewsletterPage()
        #expect(complete.isComplete)
        #expect(complete.scannedMessageCount == 2)
        #expect(complete.subscriptions.count == 1)
        #expect(complete.subscriptions.first?.messageCount == 2)
        #expect(try await cache.read { try $0.cachedMessageIDs(accountID: account) }.isEmpty)
        #expect(await nextGmail.changes.isEmpty)
        #expect(await nextGmail.fullThreadRequests.isEmpty)
        #expect(await nextGmail.attachmentRequests.isEmpty)
        let requested = try #require(await nextGmail.metadataRequestHeaders.first)
        #expect(Set(requested).isSuperset(of: NewsletterHeaders.metadataHeaders))
        #expect(!SyncEngine.metadataHeaders.contains("List-Unsubscribe"))
    }

    @Test func sentDraftSpamTrashAndMissingUnsubscribeAreNotSubscriptions() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        for label in ["SENT", "DRAFT", "SPAM", "TRASH", "CHAT"] {
            await gmail.add(try newsletterMessage(label, labels: [label]))
        }
        await gmail.add(try newsletterMessage("personal", unsubscribe: false))
        await gmail.add(try newsletterMessage("newsletter"))
        await gmail.setRecentPages([try newsletterPage(["SENT", "DRAFT", "SPAM", "TRASH", "CHAT", "personal", "newsletter", "gone"], next: nil)])
        let snapshot = try await engine.loadNewsletterPage()
        #expect(snapshot.isComplete)
        #expect(snapshot.scannedMessageCount == 7)
        #expect(snapshot.subscriptions.map(\.latestMessageID) == ["newsletter"])
        #expect(snapshot.subscriptions.first?.oneClickURL == nil)
        #expect(snapshot.subscriptions.first?.unsubscribeURL != nil)
    }

    @Test func metadataFailureLeavesTheWholePageAvailableForRetry() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try newsletterMessage("first"))
        await gmail.add(try newsletterMessage("second"))
        await gmail.setMetadataErrors(["second": .rateLimited])
        await gmail.setRecentPages([try newsletterPage(["first", "second"], next: "older")])
        await #expect(throws: GmailError.rateLimited) { try await engine.loadNewsletterPage() }
        let snapshot = try await engine.newsletterSnapshot()
        #expect(snapshot.scannedMessageCount == 0)
        #expect(snapshot.lastError != nil)
        #expect(try await cache.read { try $0.newsletterScanState(accountID: account) }?.nextPageToken == nil)
        await gmail.setMetadataErrors([:])
        await gmail.setRecentPages([try newsletterPage(["first", "second"], next: nil)])
        #expect(try await engine.loadNewsletterPage().subscriptions.first?.messageCount == 2)
    }

    @Test func metadataBatchesAreBounded() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        let ids = (0..<100).map { "m\($0)" }
        for id in ids { await gmail.add(try newsletterMessage(id)) }
        await gmail.setRecentPages([try newsletterPage(ids, next: nil)])
        let snapshot = try await engine.loadNewsletterPage()
        #expect(snapshot.subscriptions.first?.messageCount == 100)
        #expect(await gmail.metadataRequests.map(\.count) == [25, 25, 25, 25])
    }

    @Test func stopAndAccountDeletionPreventLateScanWrites() async throws {
        let (engine, cache, gmail, _) = try await makeEngine()
        await gmail.add(try newsletterMessage("held"))
        await gmail.setRecentPages([try newsletterPage(["held"], next: nil)])
        let (entered, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await gmail.holdNextMetadata { signal.yield(()); signal.finish() }
        let task = Task { try await engine.loadNewsletterPage() }
        for await _ in entered { break }
        await engine.stop()
        try await cache.write { try $0.deleteAccountData(accountID: account) }
        await gmail.releaseMetadata()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await cache.read { try $0.cachedAccountIDs() }.isEmpty)
    }

    @Test func identityMismatchCannotAdvanceScan() async throws {
        let (engine, _, gmail, _) = try await makeEngine()
        await gmail.add(try newsletterMessage("first", thread: "different"))
        await gmail.setRecentPages([try newsletterPage(["first"], next: nil)])
        await #expect(throws: GmailError.self) { try await engine.loadNewsletterPage() }
        #expect(try await engine.newsletterSnapshot().scannedMessageCount == 0)
        #expect(try await engine.newsletterSnapshot().isComplete == false)
    }
}

private func newsletterMessage(_ id: String, labels: [String] = ["INBOX"], unsubscribe: Bool = true,
                               thread: String? = nil) throws -> GmailMessage {
    var headers = [["name": "From", "value": "Daily News <news@example.com>"],
                   ["name": "Subject", "value": "News of the day"], ["name": "List-Id", "value": "Daily <daily.example.com>"]]
    if unsubscribe { headers.append(["name": "List-Unsubscribe", "value": "<https://example.com/unsubscribe/\(id)>"]) }
    let json: [String: Any] = ["id": id, "threadId": thread ?? "t-\(id)", "historyId": "200",
        "internalDate": "1700000000000", "labelIds": labels, "payload": ["headers": headers]]
    return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: json))
}

private func newsletterPage(_ ids: [String], next: String?) throws -> MessageListPage {
    var json: [String: Any] = ["messages": ids.map { ["id": $0, "threadId": "t-\($0)"] }]
    if let next { json["nextPageToken"] = next }
    return try JSONDecoder().decode(MessageListPage.self, from: JSONSerialization.data(withJSONObject: json))
}
