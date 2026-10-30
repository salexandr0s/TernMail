import Foundation
import MailStore
import Observation
import SyncEngine

/// First sync, cursor gaps, cache rebuilds and resume establish quiet baselines.
@MainActor @Observable
final class MailNotificationCoordinator {
    private(set) var permission: MailNotificationPermission = .notRequested
    var error: String?
    @ObservationIgnored private let store: AccountStore
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let preferences: AccountPreferencesModel
    @ObservationIgnored private let scheduler: any MailNotificationScheduling
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var readyAccounts = Set<String>()
    @ObservationIgnored private var epochs: [String: UUID] = [:]

    init(store: AccountStore, cache: MailCache, preferences: AccountPreferencesModel,
         scheduler: any MailNotificationScheduling = NativeMailNotificationScheduler(),
         defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now }) {
        self.store = store; self.cache = cache; self.preferences = preferences; self.scheduler = scheduler; self.defaults = defaults; self.now = now
    }

    func refreshPermission() async { permission = await scheduler.permission() }

    /// Called only by the explicit notification-permission control.
    func requestPermission() async {
        do { _ = try await scheduler.requestPermission(); await refreshPermission() }
        catch { self.error = "Couldn't request notification permission." }
    }

    func prepareAccount(_ id: String) {
        epochs[id] = UUID()
        readyAccounts.remove(id)
    }

    func removeAccount(_ id: String) async {
        epochs[id] = UUID()
        readyAccounts.remove(id)
        await scheduler.removeNotifications(accountID: id)
    }

    func process(_ snapshot: MailSyncNotification) async {
        let id = snapshot.accountID
        if epochs[id] == nil { epochs[id] = UUID() }
        let epoch = epochs[id]
        guard snapshot.toHistoryID > 0 else { return }
        do {
            let current = try await store.mailPreferences(accountID: id)
            let mark = try await store.mailAlertWatermark(accountID: id)
            guard epochs[id] == epoch, !Task.isCancelled else { return }
            guard current.syncEnabled, readyAccounts.contains(id), let from = snapshot.fromHistoryID, let mark else {
                try await store.resetMailAlertDeliveryBaseline(accountID: id, historyID: snapshot.toHistoryID, at: now())
                if current.syncEnabled { readyAccounts.insert(id) }
                else { readyAccounts.remove(id) }
                return
            }
            if mark.historyID >= snapshot.toHistoryID {
                try await retryPending(accountID: id, epoch: epoch)
                return
            }
            guard mark.historyID == from else {
                // Missing sync coverage suppresses unknown new candidates, but
                // already durable, exact delivery intents can still retry.
                try await store.setMailAlertBaseline(accountID: id, historyID: snapshot.toHistoryID, at: now())
                try await retryPending(accountID: id, epoch: epoch)
                return
            }
            let profiles = try await store.mailProfiles()
            let profile = current.profileID.flatMap { profileID in profiles.first { $0.id == profileID } }
            let candidates = snapshot.messages.filter {
                $0.addedHistoryID > mark.historyID && $0.addedHistoryID <= snapshot.toHistoryID
                    && NotificationPolicy.allows($0, preferences: current, profile: profile,
                        activeProfileID: preferences.activeProfileID, at: now())
            }
            guard epochs[id] == epoch, !Task.isCancelled else { return }
            let alerts = candidates.map { PendingMailAlert(accountID: id, messageID: $0.record.id,
                threadID: $0.record.threadID, addedHistoryID: $0.addedHistoryID) }
            let advanced = try await store.enqueueMailAlerts(accountID: id,
                expectedHistoryID: mark.historyID, to: snapshot.toHistoryID, alerts: alerts)
            guard advanced, epochs[id] == epoch else { return }
            try await retryPending(accountID: id, epoch: epoch)
        } catch MailPreferencesError.accountMissing {
        } catch is CancellationError {
        } catch { self.error = "Couldn't process new-mail notifications." }
    }

    private func retryPending(accountID: String, epoch: UUID?) async throws {
        await refreshPermission()
        let pending = try await store.pendingMailAlerts(accountID: accountID)
        for alert in pending {
            guard epochs[accountID] == epoch, !Task.isCancelled else { return }
            let preferences = try await store.mailPreferences(accountID: accountID)
            let profiles = try await store.mailProfiles()
            let profile = preferences.profileID.flatMap { id in profiles.first { $0.id == id } }
            let message = try await cache.read { tx -> MailNotificationMessage? in
                guard let record = try tx.message(id: alert.messageID, accountID: accountID), record.threadID == alert.threadID else { return nil }
                return MailNotificationMessage(record: record,
                    labelIDs: try tx.currentLabels(threadID: record.threadID, accountID: accountID)[record.id] ?? [],
                    addedHistoryID: alert.addedHistoryID)
            }
            guard epochs[accountID] == epoch, !Task.isCancelled else { return }
            guard permission == .allowed, let message,
                  NotificationPolicy.allows(message, preferences: preferences, profile: profile,
                    activeProfileID: self.preferences.activeProfileID, at: now()) else {
                // Deleted/evicted sources and newly suppressed deliveries are
                // discarded explicitly; they are never counted as delivered.
                try await store.removePendingMailAlert(accountID: accountID, messageID: alert.messageID)
                continue
            }
            let record = message.record
            let action = defaults.string(forKey: MailNotificationAction.storageKey).flatMap(MailNotificationAction.init(rawValue:)) ?? .archive
            let sound = defaults.object(forKey: NotificationPolicy.soundKey) == nil || defaults.bool(forKey: NotificationPolicy.soundKey)
            try await scheduler.schedule(MailNotificationDelivery(
                id: NotificationPolicy.identifier(accountID: accountID, value: record.id, kind: "message"),
                groupID: NotificationPolicy.identifier(accountID: accountID, value: record.threadID, kind: "thread"),
                accountID: accountID, threadID: record.threadID, messageID: record.id,
                sender: String(record.sender.prefix(300)), subject: String(record.subject.prefix(500)),
                snippet: String(record.snippet.prefix(1_000)), profileID: preferences.profileID, action: action, playsSound: sound
            ))
            try await store.removePendingMailAlert(accountID: accountID, messageID: alert.messageID)
        }
        error = nil
    }

    /// A synthetic notification exercises system setup without using mail data.
    func sendTestNotification() async {
        await refreshPermission()
        guard permission == .allowed else { error = "Allow notifications in System Settings first."; return }
        do {
            try await scheduler.schedule(MailNotificationDelivery(id: "tern.mail.test", groupID: "tern.mail.test",
                accountID: "", threadID: "", messageID: "", sender: "Tern", subject: "Test notification",
                snippet: "New-mail notifications are ready.", profileID: nil, action: .archive, playsSound: true))
        } catch { self.error = "Couldn't send the test notification." }
    }
}
