import Foundation
import MailStore
import SyncEngine
import Testing
@testable import Tern

@Suite @MainActor struct MailNotificationTests {
    @Test func firstSyncResetAndResumeNeverAlertAndRepeatedHistoryDoesNotDuplicate() async throws {
        let store = try await makeStore()
        let cache = try MailCache.inMemory()
        let prefs = AccountPreferencesModel(store: store, defaults: try isolatedDefaults())
        let scheduler = TestMailScheduler()
        let model = MailNotificationCoordinator(store: store, cache: cache, preferences: prefs, scheduler: scheduler)
        try await run(delta(from: nil, to: 10, message: "initial"), through: model, cache: cache)
        #expect(await scheduler.deliveries.isEmpty)
        let incoming = delta(from: 10, to: 20, message: "new")
        try await run(incoming, through: model, cache: cache)
        try await run(incoming, through: model, cache: cache)
        #expect(await scheduler.deliveries.map(\.messageID) == ["new"])
        try await run(delta(from: nil, to: 30, message: "reset"), through: model, cache: cache)
        model.prepareAccount("a")
        try await run(delta(from: 30, to: 40, message: "resume"), through: model, cache: cache)
        try await run(delta(from: 40, to: 50, message: "after-resume"), through: model, cache: cache)
        #expect(await scheduler.deliveries.map(\.messageID) == ["new", "after-resume"])
        #expect(try await store.mailAlertWatermark(accountID: "a")?.historyID == 50)
        #expect(await scheduler.permissionRequests == 0)
    }

    @Test func missingHistoryCoverageEstablishesQuietBaseline() async throws {
        let store = try await makeStore()
        let cache = try MailCache.inMemory()
        let scheduler = TestMailScheduler()
        let model = MailNotificationCoordinator(store: store, cache: cache, preferences: AccountPreferencesModel(store: store, defaults: try isolatedDefaults()), scheduler: scheduler)
        try await run(delta(from: nil, to: 10, message: "initial"), through: model, cache: cache)
        try await run(delta(from: 15, to: 20, message: "gap"), through: model, cache: cache)
        try await run(delta(from: 20, to: 30, message: "complete"), through: model, cache: cache)
        #expect(await scheduler.deliveries.map(\.messageID) == ["complete"])
    }

    @Test func failedNativeSchedulingRetriesExactCachedMessageOnNextSync() async throws {
        let store = try await makeStore()
        let cache = try MailCache.inMemory()
        let scheduler = TestMailScheduler()
        let model = MailNotificationCoordinator(store: store, cache: cache,
            preferences: AccountPreferencesModel(store: store, defaults: try isolatedDefaults()), scheduler: scheduler)
        try await run(delta(from: nil, to: 10, message: "initial"), through: model, cache: cache)
        await scheduler.failNextSchedule()
        try await run(delta(from: 10, to: 20, message: "retry-me"), through: model, cache: cache)
        #expect(await scheduler.deliveries.isEmpty)
        #expect(try await store.pendingMailAlerts(accountID: "a").map(\.messageID) == ["retry-me"])
        #expect(try await store.mailAlertWatermark(accountID: "a")?.historyID == 20)
        // The next event has no new messages. Delivery reloads the durable
        // reference from cached metadata, without depending on stream replay.
        await model.process(MailSyncNotification(accountID: "a", fromHistoryID: 20, toHistoryID: 30))
        #expect(await scheduler.deliveries.map(\.messageID) == ["retry-me"])
        #expect(try await store.pendingMailAlerts(accountID: "a").isEmpty)
        await model.process(MailSyncNotification(accountID: "a", fromHistoryID: 30, toHistoryID: 30))
        #expect(await scheduler.deliveries.count == 1)
    }

    @Test func resumeAtSameCursorClearsOldPendingDeliveryWithoutAlerting() async throws {
        let store = try await makeStore()
        let cache = try MailCache.inMemory()
        let scheduler = TestMailScheduler()
        let model = MailNotificationCoordinator(store: store, cache: cache,
            preferences: AccountPreferencesModel(store: store, defaults: try isolatedDefaults()), scheduler: scheduler)
        try await run(delta(from: nil, to: 10, message: "initial"), through: model, cache: cache)
        await scheduler.failNextSchedule()
        try await run(delta(from: 10, to: 20, message: "before-pause"), through: model, cache: cache)
        #expect(try await store.pendingMailAlerts(accountID: "a").count == 1)
        model.prepareAccount("a")
        await model.process(MailSyncNotification(accountID: "a", fromHistoryID: 20, toHistoryID: 20))
        #expect(try await store.pendingMailAlerts(accountID: "a").isEmpty)
        #expect(await scheduler.deliveries.isEmpty)
        try await run(delta(from: 20, to: 30, message: "after-resume"), through: model, cache: cache)
        #expect(await scheduler.deliveries.map(\.messageID) == ["after-resume"])
    }

    @Test func turningSyncOffDuringPermissionReadRejectsLateNotification() async throws {
        let store = try await makeStore()
        let cache = try MailCache.inMemory()
        let scheduler = TestMailScheduler()
        let model = MailNotificationCoordinator(store: store, cache: cache, preferences: AccountPreferencesModel(store: store, defaults: try isolatedDefaults()), scheduler: scheduler)
        try await run(delta(from: nil, to: 10, message: "initial"), through: model, cache: cache)
        await scheduler.pausePermissionRead()
        let delivery = Task { try await run(delta(from: 10, to: 20, message: "late"), through: model, cache: cache) }
        try await eventually { await scheduler.isPermissionReadWaiting }
        try await store.updateMailPreferences(accountID: "a") { $0.syncEnabled = false }
        await scheduler.releasePermissionRead()
        try await delivery.value
        #expect(await scheduler.deliveries.isEmpty)
    }

    @Test func scheduledSuppressionAdvancesWatermarkWithoutReplayingOldMail() async throws {
        let store = try await makeStore()
        let cache = try MailCache.inMemory()
        let profile = MailProfile(id: "work", name: "Work", notificationSchedule: .off)
        try await store.saveMailProfile(profile)
        try await store.updateMailPreferences(accountID: "a") { $0.profileID = "work" }
        let scheduler = TestMailScheduler()
        let model = MailNotificationCoordinator(store: store, cache: cache, preferences: AccountPreferencesModel(store: store, defaults: try isolatedDefaults()), scheduler: scheduler)
        try await run(delta(from: nil, to: 10, message: "initial"), through: model, cache: cache)
        try await run(delta(from: 10, to: 20, message: "suppressed"), through: model, cache: cache)
        #expect(await scheduler.deliveries.isEmpty)
        var enabled = profile; enabled.notificationSchedule = .unrestricted
        try await store.saveMailProfile(enabled)
        try await run(delta(from: 20, to: 30, message: "allowed"), through: model, cache: cache)
        #expect(await scheduler.deliveries.map(\.messageID) == ["allowed"])
    }

    @Test func profileScheduleAndCategoryRulesFilterBeforeScheduling() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 17)))
        let profile = MailProfile(id: "work", name: "Work", notificationSchedule: .weekdays([.init(startMinute: 540, endMinute: 1020)]))
        let prefs = AccountMailPreferences(accountID: "a", profileID: "work", notificationRule: .inboxWithoutCategories)
        var message = candidate("m", at: 2)
        #expect(NotificationPolicy.allows(message, preferences: prefs, profile: profile, activeProfileID: "work", at: morning, calendar: calendar))
        #expect(!NotificationPolicy.allows(message, preferences: prefs, profile: profile, activeProfileID: "personal", at: morning, calendar: calendar))
        #expect(!NotificationPolicy.allows(message, preferences: prefs, profile: profile, activeProfileID: "work", at: evening, calendar: calendar))
        message.labelIDs.insert("CATEGORY_PROMOTIONS")
        #expect(!NotificationPolicy.allows(message, preferences: prefs, profile: profile, activeProfileID: nil, at: morning, calendar: calendar))
        message.labelIDs = ["INBOX", "TRASH"]
        #expect(!NotificationPolicy.allows(message, preferences: prefs, profile: profile, activeProfileID: nil, at: morning, calendar: calendar))
        #expect(NotificationPolicy.identifier(accountID: "a", value: "same", kind: "message") != NotificationPolicy.identifier(accountID: "b", value: "same", kind: "message"))
        #expect(NotificationPolicy.identifier(accountID: "a", value: "same", kind: "thread") != NotificationPolicy.identifier(accountID: "a", value: "same", kind: "message"))
    }

    @Test func profilePresentationUsesNicknameOrderAndClearsDeletedProfileAssignments() async throws {
        let store = try await makeStore()
        try await store.save(AccountRecord(id: "b", email: "other@example.com", displayName: nil, grantedScopes: [], addedAt: .now))
        let model = AccountPreferencesModel(store: store, defaults: try isolatedDefaults())
        await model.refresh()
        #expect(await model.saveProfile(MailProfile(id: "work", name: "Work")))
        await model.update("a") { $0.nickname = "Office"; $0.profileID = "work" }
        await model.move("b", by: -1)
        #expect(model.orderedRecords.map(\.id) == ["b", "a"])
        #expect(model.records.first(where: { $0.id == "a" }).map(model.displayName(for:)) == "Office")
        model.selectProfile("work")
        #expect(model.visibleAccountIDs == ["a"])
        await model.deleteProfile(MailProfile(id: "work", name: "Work"))
        #expect(model.activeProfileID == nil)
        #expect(model.visibleAccountIDs == ["a", "b"])
        #expect(model.preferences(for: "a").profileID == nil)
    }

    private func makeStore() async throws -> AccountStore {
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "a", email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: .now))
        try await store.updateMailPreferences(accountID: "a") { $0.notificationRule = .allMail }
        return store
    }
    private func run(_ snapshot: MailSyncNotification, through model: MailNotificationCoordinator, cache: MailCache) async throws {
        try await cache.write { tx in
            _ = try tx.upsertMessages(snapshot.messages.map { .init(record: $0.record, labelIDs: Array($0.labelIDs)) })
            try tx.rebuildThreads(Set(snapshot.messages.map(\.record.threadID)), accountID: snapshot.accountID)
        }
        await model.process(snapshot)
    }
    private func isolatedDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "tern.notification-tests." + UUID().uuidString))
    }
    private func candidate(_ id: String, at history: Int64) -> MailNotificationMessage {
        MailNotificationMessage(record: MessageRecord(accountID: "a", id: id, threadID: "thread", historyID: history,
            date: .now, snippet: "Preview", sender: "Sender", recipients: "me@example.com", cc: nil, subject: "Subject", sizeEstimate: 10),
            labelIDs: ["INBOX", "UNREAD"], addedHistoryID: history)
    }
    private func delta(from: Int64?, to: Int64, message: String) -> MailSyncNotification {
        MailSyncNotification(accountID: "a", fromHistoryID: from, toHistoryID: to, messages: [candidate(message, at: to)])
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }
}

private actor TestMailScheduler: MailNotificationScheduling {
    private(set) var deliveries: [MailNotificationDelivery] = []
    private(set) var permissionRequests = 0
    private var pausesPermission = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var remainingFailures = 0
    var isPermissionReadWaiting: Bool { waiter != nil }
    func permission() async -> MailNotificationPermission {
        if pausesPermission { await withCheckedContinuation { waiter = $0 } }
        return .allowed
    }
    func requestPermission() async throws -> Bool { permissionRequests += 1; return true }
    func schedule(_ delivery: MailNotificationDelivery) async throws {
        if remainingFailures > 0 { remainingFailures -= 1; throw URLError(.notConnectedToInternet) }
        deliveries.append(delivery)
    }
    func removeNotifications(accountID: String) async { deliveries.removeAll { $0.accountID == accountID } }
    func pausePermissionRead() { pausesPermission = true }
    func failNextSchedule() { remainingFailures += 1 }
    func releasePermissionRead() { pausesPermission = false; waiter?.resume(); waiter = nil }
}
