import Foundation
import GRDB
import Testing
@testable import MailStore

@Suite struct CalendarPreferencesTests {
    @Test func preferencesRemainIsolatedAcrossAccountsAndFollowAccountRemoval() async throws {
        let store = try AccountStore.inMemory()
        for id in ["one", "two"] { try await store.save(Self.account(id)) }
        var first = CalendarPreferences(accountID: "one", calendarID: "shared", visible: false,
            assistantAccess: .details, includeInScheduling: true, notificationsEnabled: false)
        let second = CalendarPreferences(accountID: "two", calendarID: "shared")
        try await store.saveCalendarPreferences(first)
        try await store.saveCalendarPreferences(second)
        first.assistantAccess = .availability
        try await store.saveCalendarPreferences(first)
        try await store.save(Self.account("one"))
        #expect(try await store.calendarPreferences(accountID: "one") == [first])
        #expect(try await store.calendarPreferences(accountID: "two") == [second])

        try await store.deleteAccount(id: "one")
        #expect(try await store.calendarPreferences(accountID: "one").isEmpty)
        #expect(try await store.calendarPreferences(accountID: "two") == [second])
        // A pending UI preference write cannot recreate removed-account data.
        await #expect(throws: DatabaseError.self) { try await store.saveCalendarPreferences(first) }
        try await store.save(Self.account("one"))
        #expect(try await store.calendarPreferences(accountID: "one").isEmpty)
    }

    @Test func upgradingConfigPreservesAccountsAndStartsWithCalendarAccessDisabled() async throws {
        let writer = try DatabaseQueue()
        try Schema.configMigrator.migrate(writer, upTo: "integrations-v1")
        try await writer.write { db in try Self.account("existing").insert(db) }
        let store = try AccountStore(writer: writer)
        #expect(try await store.accounts().map(\.id) == ["existing"])
        #expect(try await store.calendarPreferences(accountID: "existing").isEmpty)
        let preference = CalendarPreferences(accountID: "existing", calendarID: "primary")
        #expect(preference.assistantAccess == .off)
        #expect(!preference.includeInScheduling)
        try await store.saveCalendarPreferences(preference)
        #expect(try await store.calendarPreferences(accountID: "existing") == [preference])
    }

    @Test func preferencesSurviveReopeningConfigurationIndependentlyOfCalendarMirror() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.sqlite")
        let firstStore = try AccountStore.open(at: url)
        try await firstStore.save(Self.account("one"))
        let preference = CalendarPreferences(accountID: "one", calendarID: "personal", assistantAccess: .availability)
        try await firstStore.saveCalendarPreferences(preference)
        let mirror = try CalendarStore.inMemory()
        try await mirror.deleteAccountData(accountID: "one")
        let reopened = try AccountStore.open(at: url)
        #expect(try await reopened.calendarPreferences(accountID: "one") == [preference])
    }

    @Test func preferencesWithoutResourceIdentityAreRejected() async throws {
        let store = try AccountStore.inMemory()
        try await store.save(Self.account("one"))
        await #expect(throws: CalendarPreferencesError.missingIdentity) {
            try await store.saveCalendarPreferences(.init(accountID: "one", calendarID: ""))
        }
        #expect(try await store.calendarPreferences(accountID: "one").isEmpty)
    }

    private static func account(_ id: String) -> AccountRecord {
        .init(id: id, email: "\(id)@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now)
    }
}
