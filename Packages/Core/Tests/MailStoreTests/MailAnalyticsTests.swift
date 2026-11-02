import Foundation
import GRDB
import MessageContent
import Testing
@testable import MailStore

@Suite struct MailAnalyticsTests {
    @Test func countsUseExactContactsAndSentLabelsWithoutDuplicatingRecipients() async throws {
        let cache = try MailCache.inMemory()
        let day = analyticsDate("2026-10-20T10:00:00Z")
        let updates: [CacheTransaction.MessageUpdate] = [
            .init(record: record("received", date: day), labelIDs: [SystemLabel.inbox]),
            .init(record: record("sent", date: day, sender: "Alias <alias@example.test>",
                                 to: "Alex <ALEX@example.test>, alex@example.test", cc: "alex@example.test"), labelIDs: [SystemLabel.sent]),
            .init(record: record("self", date: day, sender: "me@example.test", to: "me@example.test"), labelIDs: [SystemLabel.sent, SystemLabel.inbox]),
            .init(record: record("lookalike", date: day, sender: "not-alex@example.test"), labelIDs: []),
            .init(record: record("received", account: "b", date: day), labelIDs: []),
            .init(record: record("draft", date: day), labelIDs: [SystemLabel.draft]),
            .init(record: record("spam", date: day), labelIDs: [SystemLabel.spam]),
            .init(record: record("trash", date: day), labelIDs: [SystemLabel.trash]),
            .init(record: record(LocalSend.messageID(localDraftID: "queued"), date: day), labelIDs: [SystemLabel.sent]),
        ]
        try await cache.write { tx in
            try tx.setOwnAddresses(["me@example.test", "alias@example.test"], accountID: "a")
            try tx.upsertAnalyticsMessages(updates)
            try tx.upsertAnalyticsMessages(updates)
        }
        let query = MailAnalyticsQuery(accountIDs: ["a"], contactAddress: " ALEX@EXAMPLE.TEST ", period: .allTime, now: day)
        let contact = try await cache.mailAnalytics(query: query)
        #expect(contact.sentCount == 1)
        #expect(contact.receivedCount == 1)
        #expect(contact.threadCount == 2)
        #expect(contact.correspondents.first?.totalCount == 2)
        let all = try await cache.mailAnalytics(query: .init(accountIDs: ["a"], period: .allTime, now: day))
        #expect(all.sentCount == 2)
        #expect(all.receivedCount == 2)
        #expect(!all.correspondents.contains { $0.address == "me@example.test" })
        #expect(try await cache.mailAnalytics(query: .init(accountIDs: [], period: .allTime, now: day)).totalCount == 0)
    }

    @Test func migrationSeedsExistingMailAndIndexSurvivesBodyAndMessageEviction() async throws {
        let writer = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(writer, upTo: "date-header-offset-v1")
        let message = record("old", date: analyticsDate("2020-01-12T12:00:00Z"))
        try await writer.write { db in
            try message.insert(db)
            try db.execute(sql: "INSERT INTO messageLabel (accountID,messageID,labelID) VALUES ('a','old','INBOX')")
        }
        let cache = try MailCache(writer: writer)
        try await cache.write { tx in _ = try tx.deleteMessages(ids: ["old"], accountID: "a") }
        let beforeDelete = try await cache.mailAnalytics(query: .init(accountIDs: ["a"], period: .allTime))
        #expect(beforeDelete.receivedCount == 1)
        #expect(beforeDelete.firstReceivedAt == message.date)
        #expect(beforeDelete.coverage.first?.isComplete == false)
        try await cache.write { try $0.deleteAnalyticsMessages(messageIDs: ["old"], accountID: "a") }
        #expect(try await cache.mailAnalytics(query: .init(accountIDs: ["a"], period: .allTime)).totalCount == 0)
    }

    @Test func reconciliationCommitsOnlyAtEndAndRejectsSupersededPages() async throws {
        let cache = try MailCache.inMemory()
        let date = analyticsDate("2026-10-25T12:00:00Z")
        let old = CacheTransaction.MessageUpdate(record: record("old", date: date), labelIDs: [])
        let kept = CacheTransaction.MessageUpdate(record: record("kept", date: date), labelIDs: [])
        try await cache.write { try $0.upsertAnalyticsMessages([old, kept]) }
        let start = try await cache.write { try $0.beginAnalyticsHistory(accountID: "a") }
        let partial = try await cache.write {
            try $0.commitAnalyticsHistoryPage(start, updates: [kept], missing: [], nextPageToken: "last", loadedAt: date)
        }
        #expect(!partial.isComplete)
        #expect(partial.indexedMessageCount == 2)
        let next = try #require(try await cache.read { try $0.analyticsIndexState(accountID: "a") })
        let finished = try await cache.write {
            try $0.commitAnalyticsHistoryPage(next, updates: [], missing: [], nextPageToken: nil, loadedAt: date)
        }
        #expect(finished.isComplete)
        #expect(finished.indexedMessageCount == 1)
        #expect(finished.historyLoadedAt == date)
        let restarted = try await cache.write { try $0.beginAnalyticsHistory(accountID: "a", restart: true) }
        let stale = try await cache.write {
            try $0.commitAnalyticsHistoryPage(next, updates: [old], missing: [], nextPageToken: nil, loadedAt: date)
        }
        #expect(!stale.isComplete)
        #expect(stale.indexedMessageCount == 1)
        #expect(stale.historyLoadedAt == date)
        try await cache.write { try $0.failAnalyticsHistory(restarted, paginationExpired: false) }
        #expect(try await cache.read { try $0.analyticsCoverage(accountID: "a") }.lastError != nil)
        try await cache.write { try $0.deleteAccountData(accountID: "a") }
        #expect(try await cache.read { try $0.analyticsIndexState(accountID: "a") } == nil)
        #expect(try await cache.read { try $0.cachedAccountIDs() }.isEmpty)
    }

    @Test func newerLabelsWinOverOldPagesAndTrashedMailCanReturn() async throws {
        let cache = try MailCache.inMemory()
        let message = record("one", date: analyticsDate("2026-10-20T12:00:00Z"))
        try await cache.write { tx in
            try tx.upsertAnalyticsMessages([.init(record: message, labelIDs: [])])
            try tx.applyAnalyticsLabelChange(messageID: "one", added: [SystemLabel.trash], removed: [], historyID: 20, accountID: "a")
            try tx.upsertAnalyticsMessages([.init(record: message, labelIDs: [])])
        }
        #expect(try await cache.mailAnalytics(query: .init(accountIDs: ["a"], period: .allTime)).totalCount == 0)
        try await cache.write { try $0.applyAnalyticsLabelChange(messageID: "one", added: [], removed: [SystemLabel.trash], historyID: 21, accountID: "a") }
        #expect(try await cache.mailAnalytics(query: .init(accountIDs: ["a"], period: .allTime)).totalCount == 1)
    }

    @Test func chartFillsCalendarDaysAndMilestonesIgnoreSelectedPeriod() async throws {
        let cache = try MailCache.inMemory()
        let old = record("old", date: analyticsDate("2020-01-01T12:00:00Z"))
        let recent = record("recent", date: analyticsDate("2026-10-25T12:00:00Z"))
        try await cache.write { try $0.upsertAnalyticsMessages([.init(record: old, labelIDs: []), .init(record: recent, labelIDs: [])]) }
        let query = MailAnalyticsQuery(accountIDs: ["a"], period: .month, now: analyticsDate("2026-11-02T12:00:00Z"),
            timeZone: try #require(TimeZone(identifier: "Europe/Vienna")))
        let snapshot = try await cache.mailAnalytics(query: query)
        #expect(snapshot.receivedCount == 1)
        #expect(snapshot.firstReceivedAt == old.date)
        #expect(snapshot.buckets.count == 30)
        #expect(snapshot.bucketUnit == .day)
        #expect(snapshot.buckets.reduce(0) { $0 + $1.receivedCount } == 1)
        #expect(Set(snapshot.buckets.map(\.date)).count == 30)
    }

    @Test func profileSourcesKeepCompleteFieldsAndRejectOversizedUTF8() async throws {
        let cache = try MailCache.inMemory()
        let message = record("profile", date: analyticsDate("2026-10-20T12:00:00Z"))
        let oversized = String(repeating: "é", count: SenderProfileLinks.maximumInputBytes / 2 + 1)
        let html = "<div class='gmail_signature'><a href='https://github.com/alex'>GitHub</a></div>"
        try await cache.write { tx in
            try tx.upsertMessages([.init(record: message, labelIDs: [])])
            try tx.saveBodies([MessageBodyRecord(accountID: "a", messageID: "profile", html: html, plainText: oversized, fetchedAt: message.date)])
        }
        let snapshot = try await cache.mailAnalytics(query: .init(accountIDs: ["a"], contactAddress: "alex@example.test"))
        let source = try #require(snapshot.profileSources.first)
        #expect(source.plainText == nil)
        #expect(source.html == html)
    }

    private func record(_ id: String, account: String = "a", date: Date, sender: String = "Alex <alex@example.test>",
                        to: String = "me@example.test", cc: String? = nil) -> MessageRecord {
        MessageRecord(accountID: account, id: id, threadID: "t-" + id, historyID: 10, date: date, snippet: "",
            sender: sender, recipients: to, cc: cc, subject: "Subject", sizeEstimate: 0)
    }
}

private func analyticsDate(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
