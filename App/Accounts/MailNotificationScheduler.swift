import Foundation
import UserNotifications

enum MailNotificationPermission: Sendable { case notRequested, denied, allowed }

protocol MailNotificationScheduling: Sendable {
    func permission() async -> MailNotificationPermission
    func requestPermission() async throws -> Bool
    func schedule(_ delivery: MailNotificationDelivery) async throws
    func removeNotifications(accountID: String) async
}

actor NativeMailNotificationScheduler: MailNotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    func permission() async -> MailNotificationPermission {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return .notRequested
        case .authorized, .provisional, .ephemeral: return .allowed
        default: return .denied
        }
    }

    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func schedule(_ delivery: MailNotificationDelivery) async throws {
        let content = UNMutableNotificationContent()
        content.title = delivery.sender
        content.subtitle = delivery.subject
        content.body = delivery.snippet
        content.threadIdentifier = delivery.groupID
        content.categoryIdentifier = MailNotificationCategories.identifier(for: delivery.action)
        content.filterCriteria = "tern.mail.profile:" + (delivery.profileID ?? "all")
        content.userInfo = ["mailAccountID": delivery.accountID, "mailThreadID": delivery.threadID, "mailMessageID": delivery.messageID]
        let effectsEnabled = await MainActor.run { UserDefaults.standard.bool(forKey: MailSounds.enabledKey) }
        let usesEffect = delivery.playsSound && effectsEnabled
        if delivery.playsSound && !usesEffect { content.sound = .default }
        try await center.add(UNNotificationRequest(identifier: delivery.id, content: content, trigger: nil))
        if usesEffect {
            await MainActor.run {
                // The system mutes alerts for a conversation on screen; Tern's own sound does too.
                guard !MailNotificationRouter.shared.isShowing(accountID: delivery.accountID, threadID: delivery.threadID) else { return }
                MailSounds.play(.newMail)
            }
        }
    }

    func removeNotifications(accountID: String) async {
        let pending = await center.pendingNotificationRequests().filter { $0.content.userInfo["mailAccountID"] as? String == accountID }.map(\.identifier)
        let delivered = await center.deliveredNotifications().filter { $0.request.content.userInfo["mailAccountID"] as? String == accountID }.map(\.request.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }
}
