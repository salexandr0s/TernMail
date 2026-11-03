import Foundation
import MessageContent
import Testing
@testable import MailStore

@Suite struct NewsletterStoreTests {
    @Test func countsDistinctMessagesAndSeparatesListsAndAccounts() async throws {
        let cache = try MailCache.inMemory()
        let first = try await cache.write { try $0.beginNewsletterScan(accountID: "a") }
        let page = [message("one", state: first, date: 10), message("two", state: first, date: 20),
                    message("other", state: first, list: "other.example.com", date: 30)]
        _ = try await cache.write { try $0.commitNewsletterPage(first, messages: page, nextPageToken: "next", now: .now) }
        let next = try #require(try await cache.read { try $0.newsletterScanState(accountID: "a") })
        let complete = try await cache.write {
            try $0.commitNewsletterPage(next, messages: page, nextPageToken: nil, now: .now)
        }
        #expect(complete.scannedMessageCount == 3)
        #expect(complete.subscriptions.count == 2)
        #expect(complete.subscriptions.first?.messageCount == 2)
        #expect(complete.subscriptions.first?.latestMessageID == "two")
        let second = try await cache.write { try $0.beginNewsletterScan(accountID: "b") }
        let otherAccount = message("one", state: second)
        let other = try await cache.write {
            try $0.commitNewsletterPage(second, messages: [otherAccount], nextPageToken: nil, now: .now)
        }
        #expect(Set(complete.subscriptions.map(\.id)).isDisjoint(with: Set(other.subscriptions.map(\.id))))
    }

    @Test func refreshRetainsPreviousRowsUntilCompletionAndRejectsStalePages() async throws {
        let cache = try MailCache.inMemory()
        let old = try await cache.write { try $0.beginNewsletterScan(accountID: "a") }
        let original = message("old", state: old)
        _ = try await cache.write { try $0.commitNewsletterPage(old, messages: [original], nextPageToken: nil, now: .now) }
        let refresh = try await cache.write { try $0.beginNewsletterScan(accountID: "a", restart: true) }
        let replacement = message("new", state: refresh)
        let partial = try await cache.write {
            try $0.commitNewsletterPage(refresh, messages: [replacement], nextPageToken: "next", now: .now)
        }
        #expect(partial.isRefreshing)
        #expect(!partial.isComplete)
        #expect(partial.subscriptions.first?.latestMessageID == "old")
        let next = try #require(try await cache.read { try $0.newsletterScanState(accountID: "a") })
        _ = try await cache.write { try $0.commitNewsletterPage(old, messages: [original], nextPageToken: nil, now: .now) }
        #expect(try await cache.read { try $0.newsletterScanState(accountID: "a") } == next)
        let completed = try await cache.write {
            try $0.commitNewsletterPage(next, messages: [], nextPageToken: nil, now: .now)
        }
        #expect(completed.isComplete)
        #expect(!completed.isRefreshing)
        #expect(completed.subscriptions.first?.latestMessageID == "new")
        #expect(completed.scannedMessageCount == 1)
    }

    @Test func detectsPaginationCyclesWithoutCommittingTheirPage() async throws {
        let cache = try MailCache.inMemory()
        let first = try await cache.write { try $0.beginNewsletterScan(accountID: "a") }
        _ = try await cache.write { try $0.commitNewsletterPage(first, messages: [], nextPageToken: "one", now: .now) }
        let second = try #require(try await cache.read { try $0.newsletterScanState(accountID: "a") })
        _ = try await cache.write { try $0.commitNewsletterPage(second, messages: [], nextPageToken: "two", now: .now) }
        let third = try #require(try await cache.read { try $0.newsletterScanState(accountID: "a") })
        let invalid = message("invalid", state: third)
        await #expect(throws: NewsletterStoreError.self) {
            try await cache.write { try $0.commitNewsletterPage(third, messages: [invalid], nextPageToken: "one", now: .now) }
        }
        #expect(try await cache.newsletters(accountID: "a").scannedMessageCount == 0)
        #expect(try await cache.read { try $0.newsletterScanState(accountID: "a") }?.nextPageToken == "two")
    }

    @Test func requestClaimsAreExclusiveAndStaleResultsCannotOverwriteRetries() async throws {
        let cache = try MailCache.inMemory()
        let id = try await seed(cache)
        #expect(try await cache.write { try $0.claimNewsletterRequest(id: id, accountID: "a", requestID: "owner:one", now: .now) } != nil)
        #expect(try await cache.write { try $0.claimNewsletterRequest(id: id, accountID: "a", requestID: "owner:two", now: .now) } == nil)
        try await cache.write { try $0.recoverNewsletterRequests(accountID: "a", ownerID: "owner", now: .now) }
        #expect(try await cache.newsletters(accountID: "a").subscriptions.first?.status == .requesting)
        #expect(try await cache.write { try $0.resetNewsletterStatus(id: id, accountID: "a") } == nil)
        try await cache.write { try $0.recoverNewsletterRequests(accountID: "a", ownerID: "next", now: .now) }
        #expect(try await cache.newsletters(accountID: "a").subscriptions.first?.status == .failed)
        _ = try await cache.write { try $0.claimNewsletterRequest(id: id, accountID: "a", requestID: "next:two", now: .now) }
        try await cache.write {
            try $0.finishNewsletterRequest(id: id, accountID: "a", requestID: "owner:one", accepted: true, now: .now)
        }
        #expect(try await cache.newsletters(accountID: "a").subscriptions.first?.status == .requesting)
        try await cache.write {
            try $0.finishNewsletterRequest(id: id, accountID: "a", requestID: "next:two", accepted: true, now: .now)
        }
        #expect(try await cache.newsletters(accountID: "a").subscriptions.first?.status == .requested)
        #expect(try await cache.write { try $0.markNewsletterOpened(id: id, accountID: "a", now: .now) } == nil)
    }

    @Test func manualCompletionRequiresOpeningAndOutcomesSurviveRefresh() async throws {
        let cache = try MailCache.inMemory()
        let id = try await seed(cache)
        #expect(try await cache.write { try $0.confirmNewsletterUnsubscribed(id: id, accountID: "a", now: .now) } == nil)
        #expect(try await cache.write { try $0.markNewsletterOpened(id: id, accountID: "a", now: .now) }?.status == .opened)
        #expect(try await cache.write { try $0.confirmNewsletterUnsubscribed(id: id, accountID: "a", now: .now) }?.status == .completed)
        let refresh = try await cache.write { try $0.beginNewsletterScan(accountID: "a", restart: true) }
        let new = message("later", state: refresh, date: 100)
        let snapshot = try await cache.write { try $0.commitNewsletterPage(refresh, messages: [new], nextPageToken: nil, now: .now) }
        #expect(snapshot.subscriptions.first?.status == .completed)
        #expect(snapshot.subscriptions.first?.latestMessageID == "later")
        #expect(try await cache.write { try $0.resetNewsletterStatus(id: id, accountID: "a") }?.status == .active)
    }

    @Test func deletingAnAccountRemovesTheIndexCheckpointsAndOutcomes() async throws {
        let cache = try MailCache.inMemory()
        let id = try await seed(cache)
        _ = try await cache.write { try $0.claimNewsletterRequest(id: id, accountID: "a", requestID: "owner:one", now: .now) }
        try await cache.write { try $0.deleteAccountData(accountID: "a") }
        #expect(try await cache.read { try $0.cachedAccountIDs() }.isEmpty)
        #expect(try await cache.newsletters(accountID: "a").subscriptions.isEmpty)
        try await cache.write {
            try $0.finishNewsletterRequest(id: id, accountID: "a", requestID: "owner:one", accepted: true, now: .now)
        }
        #expect(try await cache.read { try $0.cachedAccountIDs() }.isEmpty)
    }

    private func seed(_ cache: MailCache) async throws -> String {
        let state = try await cache.write { try $0.beginNewsletterScan(accountID: "a") }
        let item = message("one", state: state)
        let snapshot = try await cache.write { try $0.commitNewsletterPage(state, messages: [item], nextPageToken: nil, now: .now) }
        return try #require(snapshot.subscriptions.first?.id)
    }

    private func message(_ id: String, state: NewsletterScanState, list: String = "daily.example.com", date: TimeInterval = 10) -> NewsletterMessage {
        let endpoint = URL(string: "https://example.com/unsubscribe/\(id)")
        return NewsletterMessage(accountID: state.accountID, generation: state.generation, messageID: id,
            threadID: "t-\(id)", date: Date(timeIntervalSince1970: date), subject: "Daily newsletter",
            sender: .init(name: "Daily News", address: "news@example.com"),
            options: .init(listID: list, webURL: endpoint, mailtoURL: nil, oneClickURL: endpoint))
    }
}
