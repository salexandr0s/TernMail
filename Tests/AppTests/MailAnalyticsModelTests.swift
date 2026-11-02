import Foundation
import GmailAPI
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct MailAnalyticsModelTests {
    @Test func dateObservationChangesAtMidnightAndWhenTimeZoneChanges() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let vienna = try #require(TimeZone(identifier: "Europe/Vienna"))
        let before = Date(timeIntervalSince1970: 1_793_662_200) // 2026-11-02 23:30 UTC.
        let sameDay = before.addingTimeInterval(60)
        let tomorrow = before.addingTimeInterval(3_600)
        #expect(AnalyticsCalendarContext(now: before, timeZone: utc) == AnalyticsCalendarContext(now: sameDay, timeZone: utc))
        #expect(AnalyticsCalendarContext(now: before, timeZone: utc) != AnalyticsCalendarContext(now: tomorrow, timeZone: utc))
        #expect(AnalyticsCalendarContext(now: before, timeZone: utc) != AnalyticsCalendarContext(now: before, timeZone: vienna))
    }

    @Test func changingAccountRejectsUpdatesFromThePreviousObservation() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.upsertAnalyticsMessages([Self.message(account: "a", id: "a1"), Self.message(account: "b", id: "b1")])
        }
        let model = MailAnalyticsModel()
        let first = Task { await model.observe(cache: cache, query: .init(accountIDs: ["a"], period: .allTime)) }
        defer { first.cancel(); model.stop() }
        try await waitUntil { model.snapshot?.coverage.first?.accountID == "a" }
        let second = Task { await model.observe(cache: cache, query: .init(accountIDs: ["b"], period: .allTime)) }
        defer { second.cancel() }
        first.cancel()
        try await waitUntil { model.snapshot?.coverage.first?.accountID == "b" }
        try await cache.write { tx in
            try tx.upsertAnalyticsMessages([Self.message(account: "a", id: "a2"), Self.message(account: "a", id: "a3")])
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.snapshot?.coverage.map(\.accountID) == ["b"])
        #expect(model.snapshot?.receivedCount == 1)
        #expect(model.error == nil)
    }

    @Test func failedAndPausedAccountsDoNotPreventOtherHistoryFromLoading() async throws {
        let mailbox = try await historyMailbox()
        var requests: [(String, Bool)] = []
        let model = MailAnalyticsModel { owner, restart in
            requests.append((owner.account.id, restart))
            if owner.account.id == "failed" { throw GmailError.unauthorized }
            return MailAnalyticsCoverage(accountID: owner.account.id, indexedMessageCount: 1,
                isComplete: requests.filter { $0.0 == owner.account.id }.count == 2)
        }
        defer { model.stop() }
        model.loadHistory(accounts: mailbox.accounts, restart: true)
        try await waitUntil { !model.isLoadingHistory }
        #expect(requests.map(\.0) == ["failed", "healthy", "healthy"])
        #expect(requests.map(\.1) == [true, true, false])
        #expect(model.historyPagesLoaded == 2)
        #expect(model.historyAccountName == nil)
        #expect(model.historyError?.contains("failed@example.invalid: Sign in again") == true)
        #expect(model.historyError?.contains("paused@example.invalid: Mail sync is paused") == true)
        #expect(model.historyError?.contains("healthy@example.invalid") == false)
        await mailbox.stop()
    }

    @Test func cancellingHistoryStopsBeforeTheNextAccountWithoutReportingFailure() async throws {
        let mailbox = try await historyMailbox()
        var requests: [String] = []
        let model = MailAnalyticsModel { owner, _ in
            requests.append(owner.account.id)
            try await Task.sleep(for: .seconds(30))
            return MailAnalyticsCoverage(accountID: owner.account.id, indexedMessageCount: 0, isComplete: true)
        }
        defer { model.stop() }
        model.loadHistory(accounts: mailbox.accounts, restart: false)
        try await waitUntil { !requests.isEmpty }
        model.cancelHistory()
        try await waitUntil { !model.isLoadingHistory }
        #expect(requests == ["failed"])
        #expect(model.historyError == nil)
        #expect(model.historyPagesLoaded == 0)
        await mailbox.stop()
    }

    private func historyMailbox() async throws -> MailboxModel {
        let account = AccountRecord(id: "failed", email: "failed@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now)
        let mailbox = MailboxModel(account: account, cache: try MailCache.inMemory(), gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory)
        for id in ["healthy", "paused"] {
            await mailbox.addAccount(AccountRecord(id: id, email: "\(id)@example.invalid", displayName: nil,
                grantedScopes: [], addedAt: .now), gmail: AuditGmail(), syncEnabled: id != "paused")
        }
        return mailbox
    }

    nonisolated private static func message(account: String, id: String) -> CacheTransaction.MessageUpdate {
        .init(record: .init(accountID: account, id: id, threadID: id, historyID: 1,
            date: .now, snippet: "", sender: "Alex <alex@example.invalid>", recipients: "owner@example.invalid",
            cc: nil, subject: "A message", sizeEstimate: 100), labelIDs: [SystemLabel.inbox])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
