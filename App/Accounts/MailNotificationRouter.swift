import AppKit
import Foundation
import UserNotifications

/// One system delegate routes both mail and Calendar notifications.
@MainActor final class MailNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MailNotificationRouter()
    struct Target: Sendable, Equatable {
        var accountID: String
        var threadID: String
        var messageID: String
        var action: MailNotificationAction?
    }
    private var pending: [Target] = []
    private var handler: ((Target) async -> Void)?

    func install() { UNUserNotificationCenter.current().delegate = self }
    func unbind() { handler = nil }
    func bind(_ handler: @escaping (Target) async -> Void) {
        self.handler = handler
        let targets = pending; pending = []
        Task { [weak self] in for target in targets { await self?.route(target) } }
    }
    private func route(_ target: Target) async {
        guard let handler else { pending.append(target); return }
        await handler(target)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.identifier.hasPrefix("tern.calendar.") {
            await CalendarNotificationRouter.shared.userNotificationCenter(center, didReceive: response)
            return
        }
        guard response.notification.request.identifier.hasPrefix("tern.mail.") else { return }
        let values = response.notification.request.content.userInfo
        guard let account = values["mailAccountID"] as? String, let thread = values["mailThreadID"] as? String,
              let message = values["mailMessageID"] as? String,
              [account, thread, message].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else { return }
        let action: MailNotificationAction?
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier { action = nil }
        else if response.actionIdentifier.hasPrefix("tern.mail.action.") {
            guard let value = MailNotificationAction(rawValue: String(response.actionIdentifier.dropFirst("tern.mail.action.".count))) else { return }
            action = value
        } else { return }
        await route(Target(accountID: account, threadID: thread, messageID: message, action: action))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.identifier.hasPrefix("tern.calendar.") {
            return await CalendarNotificationRouter.shared.userNotificationCenter(center, willPresent: notification)
        }
        return notification.request.identifier.hasPrefix("tern.mail.") ? [.banner, .sound] : []
    }
}
