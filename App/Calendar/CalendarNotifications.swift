import CryptoKit
import Foundation
import GmailAPI
import UserNotifications

@MainActor
final class CalendarNotifications {
    private let center = UNUserNotificationCenter.current()
    private static let prefix = "tern.calendar."
    private var generation = 0

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func remove(accountID: String, calendarID: String? = nil) async {
        generation += 1
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.identifier.hasPrefix(Self.prefix) && $0.content.userInfo["accountID"] as? String == accountID
                && (calendarID == nil || $0.content.userInfo["calendarID"] as? String == calendarID)
        }.map(\.identifier))
    }

    func reconcile(events: [CalendarDisplayEvent], calendars: [CalendarDisplayCalendar],
                   completeKeys: Set<String>, now: Date = .now) async {
        let revision = generation
        let settings = await center.notificationSettings()
        guard revision == generation else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let pending = await center.pendingNotificationRequests()
        guard revision == generation else { return }
        var wanted: [String: UNNotificationRequest] = [:]
        for item in events where !item.event.isCancelled && !item.event.isDeclined {
            guard completeKeys.contains(item.calendarKey),
                  let owner = calendars.first(where: { $0.id == item.calendarKey }) else { continue }
            let start = item.start
            let reminders = item.event.reminders?.useDefault != false
                ? owner.entry.defaultReminders ?? [] : item.event.reminders?.overrides ?? []
            for reminder in reminders where reminder.method == "popup" {
                let triggerDate = start.addingTimeInterval(-Double(reminder.minutes) * 60)
                guard triggerDate > now, triggerDate <= now.addingTimeInterval(7 * 86400) else { continue }
                let key = "\(item.id)|\(start.timeIntervalSince1970)|\(reminder.minutes)"
                let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                let identifier = Self.prefix + digest
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = start.formatted(date: .abbreviated, time: .shortened)
                content.sound = .default
                content.userInfo = ["accountID": item.accountID, "calendarID": item.calendarID,
                    "calendarKey": item.calendarKey, "eventID": item.event.id]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, triggerDate.timeIntervalSinceNow), repeats: false)
                wanted[identifier] = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            }
        }
        let obsolete = pending.filter {
            $0.identifier.hasPrefix(Self.prefix)
                && completeKeys.contains($0.content.userInfo["calendarKey"] as? String ?? "")
                && wanted[$0.identifier] == nil
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        for request in wanted.values {
            guard revision == generation else { return }
            try? await center.add(request)
            if revision != generation {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier]); return
            }
        }
    }
}

extension CalendarModel {
    func requestNotifications() async {
        do {
            if try await notifications.requestAuthorization() { await refreshNotifications() }
            else { errorMessage = "Allow Tern notifications in System Settings to receive event alerts." }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshNotifications() async {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar") else { return }
        let revision = lifecycleRevision
        let reminderRevision = notificationRevision
        let start = Date()
        // Google reminders may precede an event by up to four weeks. Include
        // those future events when scheduling the next seven days of alerts.
        guard let end = calendar.date(byAdding: .day, value: 35, to: start) else { return }
        var found: [CalendarDisplayEvent] = []
        var complete = Set<String>()
        for owner in calendars where preferences[owner.id]?.notificationsEnabled != false {
            guard revision == lifecycleRevision, reminderRevision == notificationRevision else { return }
            guard let engine = engines[owner.accountID], owner.entry.canReadDetails else { continue }
            guard let result = try? await engine.occurrences(calendarID: owner.calendarID, start: start, end: end),
                  result.isComplete, !result.isStale else { continue }
            guard revision == lifecycleRevision, reminderRevision == notificationRevision else { return }
            complete.insert(owner.id)
            found += result.events.map { CalendarDisplayEvent(event: $0, accountID: owner.accountID,
                calendarID: owner.calendarID, colorHex: owner.colorHex, canEdit: owner.canWrite,
                fallbackTimeZoneID: calendar.timeZone.identifier) }
        }
        guard revision == lifecycleRevision, reminderRevision == notificationRevision else { return }
        await notifications.reconcile(events: found, calendars: calendars, completeKeys: complete)
    }
}
