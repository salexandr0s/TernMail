import Foundation
import UserNotifications

struct FollowUpNotification: Sendable, Equatable {
    var id: String
    var accountID: String
    var commitmentID: String
    var title: String
    var body: String
}

protocol FollowUpNotificationScheduling: Sendable {
    func permission() async -> MailNotificationPermission
    func requestPermission() async throws -> Bool
    func schedule(_ notification: FollowUpNotification) async throws
    func remove(id: String) async
    func removeAccount(_ accountID: String) async
}

actor NativeFollowUpNotificationScheduler: FollowUpNotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    func permission() async -> MailNotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notRequested
        case .authorized, .provisional, .ephemeral: .allowed
        default: .denied
        }
    }

    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func schedule(_ notification: FollowUpNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = ["followUpAccountID": notification.accountID,
                            "followUpCommitmentID": notification.commitmentID]
        // Conditional reminders are checked by Tern immediately before delivery.
        try await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    func remove(id: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func removeAccount(_ accountID: String) async {
        let pending = await center.pendingNotificationRequests().filter {
            $0.content.userInfo["followUpAccountID"] as? String == accountID
        }.map(\.identifier)
        let delivered = await center.deliveredNotifications().filter {
            $0.request.content.userInfo["followUpAccountID"] as? String == accountID
        }.map(\.request.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
}

/// Synthetic app hosts must never ask for system permission or deliver alerts.
actor SilentFollowUpNotificationScheduler: FollowUpNotificationScheduling {
    func permission() async -> MailNotificationPermission { .denied }
    func requestPermission() async throws -> Bool { false }
    func schedule(_ notification: FollowUpNotification) async throws {}
    func remove(id: String) async {}
    func removeAccount(_ accountID: String) async {}
}
