import Foundation
import GRDB
import MessageContent
import Testing
@testable import MailStore

@Suite struct MailPreferencesStoreTests {
    @Test func upgradePreservesAccountsAndSuppliesSafeDefaults() async throws {
        let queue = try DatabaseQueue()
        try Schema.configMigrator.migrate(queue, upTo: "calendar-preferences-v1")
        try await queue.write { db in
            try AccountRecord(id: "a", email: "a@example.test", displayName: "A", grantedScopes: [], addedAt: .distantPast).insert(db)
        }
        let store = try AccountStore(writer: queue)
        #expect(try await store.mailPreferences(accountID: "a") == AccountMailPreferences(accountID: "a"))
        #expect(try await store.mailFavorites() == MailFavorite.defaults)
        #expect(try await store.accounts().first?.displayName == "A")
        #expect(try await store.mailAlertWatermark(accountID: "a") == nil)
    }

    @Test func concurrentPreferenceEditsAndProfileDeletionPreserveUnrelatedFields() async throws {
        let store = try await makeStore()
        try await store.saveMailProfile(MailProfile(id: "work", name: "Work"))
        async let nickname = store.updateMailPreferences(accountID: "a") { $0.nickname = "Personal" }
        async let profile = store.updateMailPreferences(accountID: "a") { $0.profileID = "work"; $0.notificationRule = .inbox }
        _ = try await (nickname, profile)
        let value = try await store.mailPreferences(accountID: "a")
        #expect(value.nickname == "Personal")
        #expect(value.profileID == "work")
        #expect(value.notificationRule == .inbox)
        #expect(try await store.mailPreferences(accountID: "b").nickname == nil)
        try await store.deleteMailProfile(id: "work")
        let ungrouped = try await store.mailPreferences(accountID: "a")
        #expect(ungrouped.profileID == nil)
        #expect(ungrouped.nickname == "Personal")
        await #expect(throws: MailPreferencesError.self) {
            try await store.updateMailPreferences(accountID: "a") { $0.profileID = "missing" }
        }
        #expect(try await store.mailPreferences(accountID: "a") == ungrouped)
    }

    @Test func senderChoicesAreNormalizedIsolatedAndDeletedWithAccount() async throws {
        let store = try await makeStore()
        try await store.setImageSenderAllowed(true, address: " Sender@Example.test ", accountID: "a")
        try await store.setSuggestionBlocked(true, address: "Sender@Example.test", accountID: "a")
        #expect(try await store.allowedImageSenders(accountID: "a") == ["sender@example.test"])
        #expect(try await store.blockedSuggestionAddresses(accountID: "a") == ["sender@example.test"])
        #expect(try await store.allowedImageSenders(accountID: "b").isEmpty)
        await #expect(throws: MailPreferencesError.self) {
            try await store.setImageSenderAllowed(true, address: "bad\r\naddress@example.test", accountID: "a")
        }
        try await store.deleteAccount(id: "a")
        await #expect(throws: MailPreferencesError.self) { try await store.mailPreferences(accountID: "a") }
        try await store.save(account("a"))
        #expect(try await store.allowedImageSenders(accountID: "a").isEmpty)
        #expect(try await store.blockedSuggestionAddresses(accountID: "a").isEmpty)
    }

    @Test func signaturesKeepRichContentAndDeletingOneClearsOnlyItsAssignments() async throws {
        let store = try await makeStore()
        let document = ComposeDocument(blocks: [.init(runs: [.init("Regards", bold: true)])])
        let template = ComposeTemplate(id: "template", name: "Follow-up", document: document)
        try await store.saveComposeTemplate(template)
        try await store.saveLocalSignature(LocalSignature(id: "one", name: "One", document: document))
        try await store.saveLocalSignature(LocalSignature(id: "two", name: "Two", document: .init(plainText: "Two")))
        try await store.saveSignatureAssignment(.init(accountID: "a", address: "ALIAS@Example.test", newMessages: .local(id: "one"),
            replies: .local(id: "two"), placeAboveQuote: false, includeSeparator: false))
        #expect(try await store.composeTemplates() == [template])
        #expect(try await store.localSignatures().first?.document == document)
        #expect(try await store.signatureAssignments(accountID: "a").first?.address == "alias@example.test")
        try await store.deleteLocalSignature(id: "one")
        let assignment = try #require(try await store.signatureAssignments(accountID: "a").first)
        #expect(assignment.newMessages == .none)
        #expect(assignment.replies == .local(id: "two"))
        #expect(!assignment.placeAboveQuote && !assignment.includeSeparator)
        await #expect(throws: MailPreferencesError.self) {
            try await store.saveSignatureAssignment(.init(accountID: "a", newMessages: .local(id: "missing")))
        }
        #expect(try await store.signatureAssignments(accountID: "b").isEmpty)
    }

    @Test func savedSearchesAndFavoritesDropRemovedAccountReferencesWithoutBroadeningScope() async throws {
        let store = try await makeStore()
        try await store.saveSavedMailSearch(.init(id: "search", name: "Receipts", query: "has:attachment", scope: .accounts(["a", "b", "a"])))
        try await store.saveMailFavorites([
            .init(id: "search-favorite", target: .savedSearch(id: "search")),
            .init(id: "label-favorite", target: .label(accountID: "a", labelID: "Label_1")),
            .init(id: "mailbox-favorite", target: .mailbox(labelID: SystemLabel.inbox, scope: .accounts(["a", "b"]))),
        ])
        let saved = try await store.mailFavorites()
        await #expect(throws: MailPreferencesError.self) {
            try await store.saveMailFavorites([.init(id: "bad", target: .savedSearch(id: "missing"))])
        }
        #expect(try await store.mailFavorites() == saved)
        try await store.deleteAccount(id: "a")
        #expect(try await store.savedMailSearches().first?.scope == .accounts(["b"]))
        let remaining = try await store.mailFavorites()
        #expect(remaining.map(\.id) == ["search-favorite", "mailbox-favorite"])
        #expect(remaining.last?.target == .mailbox(labelID: SystemLabel.inbox, scope: .accounts(["b"])))
        try await store.deleteAccount(id: "b")
        #expect(try await store.savedMailSearches().first?.scope == .accounts([]))
        try await store.save(account("a"))
        #expect(try await store.savedMailSearches().first?.scope == .accounts([]))
        try await store.deleteSavedMailSearch(id: "search")
        #expect(try await store.mailFavorites().map(\.id) == ["mailbox-favorite"])
        try await store.saveMailFavorites([])
        #expect(try await store.mailFavorites().isEmpty)
        try await store.resetMailFavorites()
        #expect(try await store.mailFavorites() == MailFavorite.defaults)
    }

    @Test func alertWatermarkCompareAndSwapRejectsStaleOrBackwardProgress() async throws {
        let store = try await makeStore()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.setMailAlertBaseline(accountID: "a", historyID: 100, at: date)
        #expect(try await store.advanceMailAlertWatermark(accountID: "a", expectedHistoryID: 100, to: 120))
        #expect(try await !store.advanceMailAlertWatermark(accountID: "a", expectedHistoryID: 100, to: 110))
        #expect(try await store.mailAlertWatermark(accountID: "a")?.historyID == 120)
        #expect(try await store.mailAlertWatermark(accountID: "a")?.baselineAt == date)
        #expect(try await store.mailAlertWatermark(accountID: "b") == nil)
        await #expect(throws: MailPreferencesError.self) {
            try await store.advanceMailAlertWatermark(accountID: "a", expectedHistoryID: 120, to: 119)
        }
        try await store.deleteAccount(id: "a")
        try await store.save(account("a"))
        #expect(try await store.mailAlertWatermark(accountID: "a") == nil)
    }

    @Test func profileScheduleUsesLocalWeekdayAndExclusiveEndingMinute() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let monday = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 2, hour: 9)))
        let schedule = ProfileNotificationSchedule.weekdays([DailyTimeRange(startMinute: 540, endMinute: 600)])
        #expect(schedule.allowsNotifications(at: monday, calendar: calendar))
        #expect(!schedule.allowsNotifications(at: monday.addingTimeInterval(3600), calendar: calendar))
        #expect(!schedule.allowsNotifications(at: monday.addingTimeInterval(5 * 86400), calendar: calendar))
        #expect(!ProfileNotificationSchedule.everyDay([.init(startMinute: 600, endMinute: 540)]).isValid)
    }

    private func makeStore() async throws -> AccountStore {
        let store = try AccountStore.inMemory()
        for id in ["a", "b"] { try await store.save(account(id)) }
        return store
    }

    private func account(_ id: String) -> AccountRecord {
        AccountRecord(id: id, email: id + "@example.test", displayName: nil, grantedScopes: [], addedAt: .distantPast)
    }
}
