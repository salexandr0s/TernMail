import Foundation
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
